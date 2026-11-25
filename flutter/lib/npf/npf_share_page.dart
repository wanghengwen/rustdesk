// Scheme C sharing page (prototype CShare): services × people with
// per-feature grants, by-person view, invite flow and confirmations.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'npf_lang.dart';
import 'npf_model.dart';
import 'npf_ui.dart';

enum NpfShareView { service, person }

class NpfSharePage extends StatefulWidget {
  final NpfModel? model;
  final NpfShareView initialView;

  /// The entry shown first in the by-person view (a person's row id,
  /// `mine`, `assist` or `peers`).
  final String? initialPerson;

  const NpfSharePage(
      {super.key,
      this.model,
      this.initialView = NpfShareView.service,
      this.initialPerson});

  @override
  State<NpfSharePage> createState() => NpfSharePageState();
}

class NpfSharePageState extends State<NpfSharePage> {
  late final NpfModel model = widget.model ?? NpfModel.instance;
  late NpfShareView view = widget.initialView;
  late String? person = widget.initialPerson;

  @override
  void initState() {
    super.initState();
    model.start();
    model.refreshShare();
    model.inviteRequest.addListener(_onInviteRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onInviteRequest());
  }

  @override
  void dispose() {
    model.inviteRequest.removeListener(_onInviteRequest);
    super.dispose();
  }

  void _onInviteRequest() {
    if (!mounted || !model.inviteRequest.value) return;
    model.inviteRequest.value = false;
    openInvite();
  }

  NpfShareData get data => model.share;
  DateTime get now => model.now();

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => Container(
        color: p.bg,
        constraints: const BoxConstraints.expand(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 18, 28, 22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(npfTr('Who this computer is shared with, and what'),
                          style: npfText(20, weight: w700, color: p.text)),
                      const SizedBox(height: 4),
                      Text(
                          npfTr(
                              '{name} · click a cell to pick what they may use; changes apply at once',
                              {'name': model.state.name}),
                          style: npfText(13, color: p.text2)),
                    ]),
              ),
              const SizedBox(width: 16),
              NpfButton(npfTr('Invite someone…'),
                  kind: NpfButtonKind.primary,
                  height: 40,
                  radius: 10,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  onTap: openInvite),
            ]),
            const SizedBox(height: 14),
            _segments(p),
            const SizedBox(height: 14),
            if (view == NpfShareView.service) _byService(p) else _byPerson(p),
          ]),
        ),
      ),
    );
  }

  Widget _segments(NpfPalette p) {
    Widget seg(NpfShareView v, String label) {
      final on = v == view;
      return Material(
        color: on ? p.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => view = v),
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            child: Text(label,
                style: npfText(13,
                    weight: on ? w600 : null, color: on ? p.text : p.text2)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
          color: p.segment, borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg(NpfShareView.service, npfTr('By service')),
        seg(NpfShareView.person, npfTr('By person')),
      ]),
    );
  }

  // ---- by service

  bool _uses(NpfMember who, NpfResource r) => who.using.contains(r.name);

  Widget _byService(NpfPalette p) {
    final people = data.people;
    final assistLive = model.state.incoming.any((c) => c.peer.temp);
    final head = npfText(14, weight: w600, color: p.text);
    final headSub = npfText(12, color: p.text3);
    Widget th(String a, String? b, {Color? bColor, bool left = false}) =>
        Padding(
          padding: EdgeInsets.symmetric(vertical: 10, horizontal: left ? 16 : 8),
          child: Column(
              crossAxisAlignment:
                  left ? CrossAxisAlignment.start : CrossAxisAlignment.center,
              children: [
                Text(a, style: head, textAlign: TextAlign.center),
                if (b != null)
                  Text(b,
                      style: bColor == null
                          ? headSub
                          : headSub.copyWith(color: bColor),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
              ]),
        );
    String personSub(NpfMember who) {
      final using = who.using.map(data.resource).whereType<NpfResource>();
      if (using.isNotEmpty) {
        return npfTr('Using {res}', {'res': using.first.title});
      }
      if (who.until != null) {
        return npfTr('until {date}', {'date': npfDate(npfTime(who.until)!)});
      }
      return _login(who) ?? npfTr('Always');
    }

    final rows = <TableRow>[
      TableRow(
        decoration: BoxDecoration(
            color: p.surface2, border: Border(bottom: BorderSide(color: p.line))),
        children: [
          th(npfTr('Shared services'), null, left: true),
          th(npfTr('Owner and admins'), npfTr('Can use everything')),
          for (final who in people)
            th(who.name, personSub(who),
                bColor: who.using.isNotEmpty ? p.greenText : null),
          th(npfTr('Assist code'),
              assistLive ? npfTr('Temporary · in use') : npfTr('Temporary · nobody now')),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            child: Text(npfTr('My devices only'),
                style: head, textAlign: TextAlign.right),
          ),
        ],
      ),
      for (final r in data.resources)
        TableRow(
          decoration:
              BoxDecoration(border: Border(bottom: BorderSide(color: p.line2))),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(r.title,
                        overflow: TextOverflow.ellipsis,
                        style: npfText(14, weight: w600, color: p.text)),
                  ),
                  if (r.isNew) ...[const SizedBox(width: 6), _newBadge(p)],
                ]),
                Text(_resourceSub(r),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: npfText(12, color: r.running ? p.text3 : p.muted)),
              ]),
            ),
            Center(
                child: Text(npfTr('All'), style: npfText(13, color: p.text2))),
            for (final who in people)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: _cell(p, who, r),
                ),
              ),
            Center(
              child: Text(
                  r.isDesktop && !r.adminOnly ? npfTr('Pick when connecting') : '—',
                  style: npfText(13,
                      color: r.isDesktop && !r.adminOnly ? p.text : p.muted)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerRight,
                child: NpfSwitch(
                    on: r.adminOnly,
                    label: '${npfTr('My devices only')}: ${r.title}',
                    onTap: () => _flipAdminOnly(r)),
              ),
            ),
          ],
        ),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        decoration: npfCard(p),
        clipBehavior: Clip.antiAlias,
        child: Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          columnWidths: {
            0: const FractionColumnWidth(0.25),
            people.length + 3: const IntrinsicColumnWidth(),
          },
          children: rows,
        ),
      ),
      const SizedBox(height: 14),
      IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(child: _codes(p)),
          const SizedBox(width: 16),
          Expanded(child: _legend(p)),
        ]),
      ),
    ]);
  }

  String _resourceSub(NpfResource r) {
    if (!r.running) return npfTr('Not running');
    if (r.isNew && r.adminOnly) return npfTr('Just installed · my devices only for now');
    if (r.svc.isNotEmpty) return r.svc;
    return r.isDesktop ? npfTr('This screen') : r.type;
  }

  Widget _newBadge(NpfPalette p) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
            color: p.newBg, borderRadius: BorderRadius.circular(999)),
        child: Text(npfTr('New'),
            style: npfText(11, weight: w600, color: p.warn)),
      );

  Widget _cell(NpfPalette p, NpfMember who, NpfResource r) {
    final can = who.canOf(r);
    final only = r.adminOnly;
    final all = can.isNotEmpty && r.features.every(can.contains);
    final (bg, fg, border, weight) = only
        ? (p.surface2, p.muted, p.lineStrong, null)
        : can.isEmpty
            ? (p.surface, p.text3, p.input, null)
            : all
                ? (p.primary, Colors.white, null, w600)
                : (p.primarySoft, p.primaryText, null, w600);
    final live = !only && _uses(who, r) && can.isNotEmpty;
    return Semantics(
      button: true,
      label: npfTr('{name} may use which features of {res}',
          {'name': who.name, 'res': r.title}),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 110),
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: border == null ? BorderSide.none : BorderSide(color: border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: only ? null : () => _edit(who, r),
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (live) ...[NpfDot(p.green, size: 7), const SizedBox(width: 5)],
                Flexible(
                  child: Text(only ? '—' : npfCapSummary(r, can),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: npfText(13, weight: weight, color: fg)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  String _scopeText(List<NpfGrant>? scope) {
    final parts = <String>[];
    for (final g in scope ?? const <NpfGrant>[]) {
      final r = data.resource(g.res);
      if (r == null) continue;
      parts.add(r.caps.length > 1
          ? '${r.title}（${npfCapSummary(r, g.can)}）'
          : r.title);
    }
    return parts.isEmpty ? npfTr('(nothing)') : parts.join(NpfLang.zh ? '、' : ', ');
  }

  Widget _codes(NpfPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: npfCard(p),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(npfTr('Unused invite codes'),
            style: npfText(14, weight: w700, color: p.text)),
        const SizedBox(height: 8),
        if (data.codes.isEmpty)
          Text(npfTr('No unused invite codes'), style: npfText(13, color: p.text3)),
        for (final c in data.codes)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          [
                            '${c.locator}-••••',
                            if (c.label.isNotEmpty) c.label,
                            npfTr('for {n} person/people', {'n': c.uses}),
                          ].join(' · '),
                          style: npfText(13, weight: w600, color: p.text)),
                      const SizedBox(height: 2),
                      Text(
                          [
                            _scopeText(c.scope),
                            if (c.expires != null)
                              npfTr('{left} left', {
                                'left': npfLeft(
                                    npfTime(c.expires)!.difference(now))
                              }),
                          ].join(' · '),
                          style: npfText(13, color: p.text3)),
                    ]),
              ),
              const SizedBox(width: 12),
              NpfButton(npfTr('Revoke'),
                  height: 32,
                  fontSize: 13,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onTap: () => _run(() => model.shareRevoke(c.locator))),
            ]),
          ),
      ]),
    );
  }

  Widget _legend(NpfPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration:
          BoxDecoration(color: p.info, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final k in [
          '<b>Owner and admins</b>: can use everything and manage this computer',
          '<b>Invited people</b>: only the features ticked in their cells; <g>●</g> means in use',
          '<b>Assist code</b>: remote desktop only, one connection; you pick the features when you approve',
          '<b>New</b>: a service just installed, my devices only until you decide',
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text.rich(TextSpan(children: _markup(p, npfTr(k))),
                style: npfText(13, color: p.text2, height: 1.55)),
          ),
      ]),
    );
  }

  /// `<b>bold</b>` and `<g>green</g>`.
  static List<InlineSpan> _markup(NpfPalette p, String s) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'<(b|g)>(.*?)</\1>');
    var at = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > at) spans.add(TextSpan(text: s.substring(at, m.start)));
      spans.add(TextSpan(
          text: m.group(2),
          style: m.group(1) == 'b'
              ? TextStyle(fontWeight: w700, color: p.text)
              : TextStyle(color: p.green)));
      at = m.end;
    }
    if (at < s.length) spans.add(TextSpan(text: s.substring(at)));
    return spans;
  }

  // ---- changes

  Future<bool> _run(Future<void> Function() f) async {
    try {
      await f();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(npfTr('Failed: {err}', {'err': e}))));
      }
      return false;
    }
  }

  /// The scope of [who] with [r] set to [next].
  List<NpfGrant> _scopeWith(NpfMember who, NpfResource? r, List<String>? next) {
    final out = <NpfGrant>[];
    for (final x in data.resources) {
      final can = x == r ? next! : who.canOf(x);
      if (can.isEmpty || (x.adminOnly && x != r)) continue;
      out.add(NpfGrant(x.name, x.caps.isEmpty ? const [] : can));
    }
    return out;
  }

  /// Sets what [who] may use of [r]; asks first when it ends a connection.
  Future<bool> _setCaps(NpfMember who, NpfResource r, List<String> next) async {
    final cur = who.canOf(r);
    final lost = cur.where((c) => !next.contains(c)).toList();
    if (lost.isNotEmpty && _uses(who, r)) {
      final ok = await _confirm(
          npfTr('This ends the connection of {name}', {'name': who.name}),
          npfTr(
              '{name} is using {res}. Without "{caps}" this connection ends; after reconnecting the new permissions apply.',
              {
                'name': who.name,
                'res': r.title,
                'caps': npfCapLongList(lost, camera: r.type == 'camera')
              }),
          npfTr('End and change'));
      if (!ok) return false;
    }
    await _run(() => model.memberSet(who.id, _scopeWith(who, r, next), who.until));
    return true;
  }

  Future<void> _flipAdminOnly(NpfResource r) async {
    if (!r.adminOnly) {
      final live = data.people
          .where((w) => _uses(w, r) && w.canOf(r).isNotEmpty)
          .firstOrNull;
      if (live != null) {
        final ok = await _confirm(
            npfTr('This ends the connection of {name}', {'name': live.name}),
            npfTr(
                '{name} is using {res}. With "my devices only" the connection ends at once and the service disappears for them.',
                {'name': live.name, 'res': r.title}),
            npfTr('End and change'));
        if (!ok) return;
      }
    }
    await _run(() =>
        model.resourceSet(r.name, r.adminOnly ? 'all' : 'admin', r.running));
  }

  Future<bool> _confirm(String title, String text, String ok) async {
    final res = await npfShowDialog<bool>(context,
        width: 380,
        builder: (ctx) {
          final p = NpfPalette.of(ctx);
          return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: npfText(17, weight: w700, color: p.text)),
                const SizedBox(height: 12),
                Text(text, style: npfText(14, color: p.text2, height: 22 / 14)),
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  NpfButton(npfTr('Not now'),
                      height: 38,
                      radius: 10,
                      onTap: () => Navigator.of(ctx).pop(false)),
                  const SizedBox(width: 10),
                  NpfButton(ok,
                      kind: NpfButtonKind.danger,
                      height: 38,
                      radius: 10,
                      onTap: () => Navigator.of(ctx).pop(true)),
                ]),
              ]);
        });
    return res == true;
  }

  /// The feature editor of one cell.
  Future<void> _edit(NpfMember who, NpfResource r) {
    return npfShowDialog(context,
        width: 400,
        builder: (ctx) => ListenableBuilder(
              listenable: model,
              builder: (ctx, _) {
                final p = NpfPalette.of(ctx);
                final w = data.people.where((x) => x.id == who.id).firstOrNull;
                if (w == null) return const SizedBox();
                final can = w.canOf(r);
                final camera = r.type == 'camera';
                final using = _uses(w, r);
                return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(npfTr('{name} · {res}', {'name': w.name, 'res': r.title}),
                          style: npfText(17, weight: w700, color: p.text)),
                      const SizedBox(height: 3),
                      Text(
                          using
                              ? npfTr('In use · removing a feature ends this connection')
                              : npfTr('Changes apply at once'),
                          style: npfText(13, color: p.text2)),
                      const SizedBox(height: 6),
                      for (final f in r.features)
                        _capRow(p, npfCap(f, camera: camera), can.contains(f),
                            () => _setCaps(w, r, npfToggleCap(r.features, can, f))),
                      const SizedBox(height: 6),
                      Text(
                          npfTr('"{base}" is the base: without it nothing else works.',
                              {'base': npfCap(r.features.first, camera: camera).long}),
                          style: npfText(12, color: p.text3)),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: NpfButton(npfTr('Done'),
                            kind: NpfButtonKind.primary,
                            height: 38,
                            radius: 10,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            onTap: () => Navigator.of(ctx).pop()),
                      ),
                    ]);
              },
            ));
  }

  Widget _capRow(NpfPalette p, NpfCap c, bool on, VoidCallback onTap) {
    final warn = c.risky && on;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          NpfCheck(on),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.long, style: npfText(14, color: p.text)),
              const SizedBox(height: 2),
              if (c.note.isNotEmpty)
                Text(warn ? npfTr('Note: {note}', {'note': c.note}) : c.note,
                    style: npfText(12, color: warn ? p.warn : p.text3)),
            ]),
          ),
        ]),
      ),
    );
  }

  // ---- by person

  /// A person's login name under the name given here, if both are known.
  String? _login(NpfMember w) =>
      w.label.isNotEmpty && w.login.isNotEmpty ? w.login : null;

  Widget _byPerson(NpfPalette p) {
    final people = data.people;
    final machines = data.machines;
    var pid = person ?? (people.isNotEmpty ? '${people.first.id}' : 'mine');
    if (pid != 'mine' &&
        pid != 'assist' &&
        !(pid == 'peers' && machines.isNotEmpty) &&
        !people.any((w) => '${w.id}' == pid)) {
      pid = 'mine';
    }
    final who = people.where((w) => '${w.id}' == pid).firstOrNull;

    Widget item(String id, String name, String sub, {bool live = false}) {
      final on = id == pid;
      return Material(
        color: on ? p.primarySoft : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => person = id),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(name,
                      overflow: TextOverflow.ellipsis,
                      style: npfText(14, weight: w600, color: p.text)),
                ),
                if (live) ...[const SizedBox(width: 6), NpfDot(p.green, size: 7)],
              ]),
              const SizedBox(height: 2),
              Text(sub, style: npfText(12, color: p.text3)),
            ]),
          ),
        ),
      );
    }

    String sub(NpfMember w) {
      final using = w.using.map(data.resource).whereType<NpfResource>();
      final parts = [
        if (_login(w) != null) _login(w)!,
        if (w.until != null)
          npfTr('until {date}', {'date': npfDate(npfTime(w.until)!)}),
        if (using.isNotEmpty) npfTr('Using {res}', {'res': using.first.title}),
      ];
      return parts.isEmpty ? npfTr('Invited person') : parts.join(' · ');
    }

    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 220,
        padding: const EdgeInsets.all(6),
        decoration: npfCard(p),
        child: Column(children: [
          item('mine', npfTr('Owner and admins'),
              npfTr('Everything · {n} admin(s)', {'n': data.admins.length}),
              live: data.admins.any((m) => m.using.isNotEmpty)),
          for (final w in people)
            item('${w.id}', w.name, sub(w), live: w.using.isNotEmpty),
          item('assist', npfTr('Assist code'),
              npfTr('Temporary · remote desktop only'),
              live: model.state.incoming.any((c) => c.peer.temp)),
          if (machines.isNotEmpty)
            item('peers', npfTr('Configured peers'),
                npfTr('Machine to machine · {n}', {'n': machines.length})),
        ]),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
          decoration: npfCard(p),
          child: who != null
              ? _personDetail(p, who)
              : pid == 'mine'
                  ? _rowsDetail(
                      p,
                      npfTr('Owner and admins'),
                      npfTr('The owner is the account logged in on this computer; admins are accounts that gave its pairing password. From any of their computers and phones they can use everything and manage this computer.'),
                      data.admins,
                      npfTr('No admins. To add one, let them type this computer\'s number and pairing password on their own computer or phone.'))
                  : pid == 'peers'
                      ? _rowsDetail(
                          p,
                          npfTr('Configured peers'),
                          npfTr('Machine to machine: devices paired by key (an exit router, another NAS, a node set up at start), not people.'),
                          machines,
                          '')
                      : _infoDetail(p, npfTr('Assist code'),
                          npfTr('Temporary code · a new one every 2 hours · one connection only, no member stays'),
                          [
                            npfTr('Remote desktop only. Every time someone connects with the assist code you pick what they get this time (view, control, files, terminal).'),
                            npfTr('After disconnecting they need a new assist code to connect again.'),
                          ]),
        ),
      ),
    ]);
  }

  Widget _infoDetail(NpfPalette p, String title, String sub, List<String> lines) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: npfText(17, weight: w700, color: p.text)),
      const SizedBox(height: 3),
      Text(sub, style: npfText(13, color: p.text2)),
      const SizedBox(height: 12),
      for (final t in lines)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration:
              BoxDecoration(border: Border(top: BorderSide(color: p.line2))),
          child: Text(t, style: npfText(13, color: p.text2, height: 20 / 13)),
        ),
    ]);
  }

  /// The admins, or the configured peers: a line each, with "Remove".
  Widget _rowsDetail(NpfPalette p, String title, String sub,
      List<NpfMember> rows, String none) {
    final line = BoxDecoration(border: Border(top: BorderSide(color: p.line2)));
    String state(NpfMember m) {
      final using = m.using.map(data.resource).whereType<NpfResource>();
      if (using.isNotEmpty) {
        return npfTr('Using {res}', {'res': using.first.title});
      }
      final since = npfTime(m.since);
      return [
        if (m.machine) m.fp else if (_login(m) != null) _login(m)!,
        if (since != null)
          m.machine
              ? npfTr('Paired {date}', {'date': npfDate(since)})
              : npfTr('Joined {date}', {'date': npfDate(since)}),
      ].join(' · ');
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: npfText(17, weight: w700, color: p.text)),
      const SizedBox(height: 3),
      Text(sub, style: npfText(13, color: p.text2, height: 20 / 13)),
      const SizedBox(height: 12),
      if (rows.isEmpty && none.isNotEmpty)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: line,
          child: Text(none, style: npfText(13, color: p.text3, height: 20 / 13)),
        ),
      for (final m in rows)
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: line,
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.name,
                    overflow: TextOverflow.ellipsis,
                    style: npfText(14, weight: w600, color: p.text)),
                const SizedBox(height: 2),
                Text(state(m),
                    overflow: TextOverflow.ellipsis,
                    style: npfText(12,
                        color: m.using.isNotEmpty ? p.greenText : p.text3)),
              ]),
            ),
            const SizedBox(width: 12),
            NpfButton(npfTr('Remove'),
                height: 28,
                fontSize: 12,
                radius: 7,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                borderColor: p.line,
                textColor: p.red,
                onTap: () => _removeRow(m)),
          ]),
        ),
    ]);
  }

  Widget _personDetail(NpfPalette p, NpfMember w) {
    final using = w.using.map(data.resource).whereType<NpfResource>().toList();
    final since = npfTime(w.since);
    final until = npfTime(w.until);
    final line = BoxDecoration(border: Border(top: BorderSide(color: p.line2)));
    final today = DateTime(now.year, now.month, now.day);
    int? untilIn(int days) =>
        today.add(Duration(days: days + 1)).millisecondsSinceEpoch ~/ 1000 - 1;
    bool sameDay(int? a, int? b) =>
        a != null && b != null && npfDate(npfTime(a)!) == npfDate(npfTime(b)!);

    final terms = [
      (npfTr('Always'), null as int?),
      (npfTr('30 days from today'), untilIn(30)),
      (npfTr('7 days from today'), untilIn(7)),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(npfTr('What {name} may use', {'name': w.name}),
                style: npfText(17, weight: w700, color: p.text)),
            const SizedBox(height: 3),
            Text(
                [
                  if (_login(w) != null) _login(w)!,
                  if (since != null)
                    npfTr('Invite code · joined {date}', {'date': npfDate(since)}),
                  if (using.isNotEmpty) npfTr('Using {res}', {'res': using.first.title}),
                ].join(' · '),
                style: npfText(13, color: p.text2)),
          ]),
        ),
        const SizedBox(width: 12),
        NpfButton(npfTr('Remove {name}', {'name': w.name}),
            height: 34,
            fontSize: 13,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            borderColor: p.redSoftLine,
            textColor: p.red,
            onTap: () => _removePerson(w)),
      ]),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.only(top: 10),
        decoration: line,
        child: Row(children: [
          SizedBox(
            width: 150,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(npfTr('How long'), style: npfText(14, weight: w600, color: p.text)),
              const SizedBox(height: 2),
              Text(
                  until != null
                      ? npfTr('Until {date}, then removed automatically',
                          {'date': npfDate(until)})
                      : npfTr('Always, until you remove them'),
                  style: npfText(12, color: until != null ? p.warn : p.text3)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final t in terms)
                NpfPill(t.$1,
                    on: t.$2 == null ? w.until == null : sameDay(w.until, t.$2),
                    onTap: () => _run(() =>
                        model.memberSet(w.id, _scopeWith(w, null, null), t.$2))),
            ]),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      for (final r in data.resources) _personRow(p, w, r, line),
      Container(
        padding: const EdgeInsets.only(top: 10),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: p.line))),
        child: Text(
            npfTr('This is kept with their account: they connect from any of their computers and phones, a new one needs no new code.'),
            style: npfText(12, color: p.text3, height: 1.5)),
      ),
    ]);
  }

  Widget _personRow(NpfPalette p, NpfMember w, NpfResource r, BoxDecoration line) {
    final can = w.canOf(r);
    final camera = r.type == 'camera';
    final using = _uses(w, r) && !r.adminOnly;
    final risky = r.adminOnly
        ? <String>[]
        : r.features
            .where((f) => can.contains(f) && npfCap(f, camera: camera).risky)
            .map((f) => npfCap(f, camera: camera).note)
            .toList();
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: line,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(
            width: 150,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.title, style: npfText(14, weight: w600, color: p.text)),
              const SizedBox(height: 2),
              Text(
                  r.adminOnly
                      ? npfTr('My devices only')
                      : using
                          ? npfTr('In use')
                          : npfCapSummary(r, can),
                  style: npfText(12, color: using ? p.greenText : p.text3)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              if (!r.adminOnly)
                for (final f in r.features)
                  NpfPill(
                      r.features.length == 1
                          ? npfTr('Can use')
                          : npfCap(f, camera: camera).short,
                      on: can.contains(f),
                      onTap: () => _setCaps(w, r, npfToggleCap(r.features, can, f))),
            ]),
          ),
        ]),
        if (risky.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 162, top: 6),
            child: Text(
                npfTr('{name}: {notes}',
                    {'name': w.name, 'notes': risky.join(NpfLang.zh ? '，' : '; ')}),
                style: npfText(12, color: p.warn)),
          ),
      ]),
    );
  }

  /// Said after removing someone: at this computer it is done at once, their
  /// account's own list follows once this computer reaches the server.
  void _removed() {
    if (!mounted || model.state.online) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(npfTr(
            'Removed on this computer; their account\'s list is updated once it reaches the server'))));
  }

  Future<void> _removePerson(NpfMember w) async {
    final using = w.using.map(data.resource).whereType<NpfResource>();
    final ok = await _confirm(
        npfTr('Remove {name}?', {'name': w.name}),
        npfTr(
            'None of their computers and phones can connect to this computer any more{live}. Then they cannot use any service of this computer; to share again, invite them again.',
            {
              'live': using.isEmpty
                  ? ''
                  : npfTr(', {res} in use ends at once', {'res': using.first.title}),
            }),
        npfTr('Remove'));
    if (!ok) return;
    if (await _run(() => model.memberRemove(w.id))) _removed();
    setState(() => person = 'mine');
  }

  /// An admin, or a configured peer.
  Future<void> _removeRow(NpfMember m) async {
    final ok = await _confirm(
        npfTr('Remove {name}?', {'name': m.name}),
        (m.using.isNotEmpty ? npfTr('They are using it and are disconnected at once. ') : '') +
            (m.machine
                ? npfTr('This configured peer can no longer connect to this computer; it must pair again.')
                : npfTr('An admin (gave the pairing password): none of their computers and phones can connect to or manage this computer any more. If they still know the pairing password they can come back; change it if needed.')),
        npfTr('Remove'));
    if (!ok) return;
    if (await _run(() => model.memberRemove(m.id)) && !m.machine) _removed();
  }

  // ---- invite

  /// "邀请别人…".
  Future<void> openInvite() => npfShowDialog(context,
      width: 480, builder: (ctx) => NpfInviteDialog(model: model));
}

/// The invite flow: pick services and features, then show the code once.
class NpfInviteDialog extends StatefulWidget {
  final NpfModel model;

  const NpfInviteDialog({super.key, required this.model});

  @override
  State<NpfInviteDialog> createState() => _NpfInviteDialogState();
}

class _NpfInviteDialogState extends State<NpfInviteDialog> {
  NpfModel get model => widget.model;
  final _label = TextEditingController();
  final pick = <String, List<String>>{};
  int term = 0; // 0 always, 30, 7 days
  NpfNewCode? code;
  List<NpfGrant> picked = const [];
  bool busy = false;
  String? error;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  NpfShareData get data => model.share;

  List<NpfGrant> get _grants => [
        for (final r in data.resources)
          if ((pick[r.name] ?? const []).isNotEmpty)
            NpfGrant(r.name, r.caps.isEmpty ? const [] : pick[r.name]!),
      ];

  Future<void> _create() async {
    final grants = _grants;
    final label = _label.text.trim();
    final ttl = term == 0 ? null : term * 86400;
    setState(() => busy = true);
    try {
      final c = await model.shareNew(grants, label, ttl);
      setState(() {
        code = c;
        picked = grants;
        busy = false;
      });
    } catch (e) {
      setState(() {
        error = npfTr('Failed: {err}', {'err': e});
        busy = false;
      });
    }
  }

  String _what(List<NpfGrant> grants) {
    final parts = <String>[];
    for (final g in grants) {
      final r = data.resource(g.res);
      if (r == null) continue;
      parts.add(r.caps.length > 1 ? '${r.title}（${npfCapSummary(r, g.can)}）' : r.title);
    }
    return parts.isEmpty ? npfTr('(nothing picked)') : parts.join(NpfLang.zh ? '、' : ', ');
  }

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    if (code != null) return _codeStep(p, code!);
    if (busy) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Text(error ?? npfTr('Creating…'), style: npfText(14, color: p.text2)),
      );
    }
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(npfTr('Invite someone · what they may use'),
              style: npfText(18, weight: w700, color: p.text)),
          const SizedBox(height: 12),
          Text(npfTr('For whom'), style: npfText(13, color: p.text2)),
          const SizedBox(height: 4),
          SizedBox(
            height: 38,
            child: TextField(
              controller: _label,
              style: npfText(14, color: p.text),
              decoration: InputDecoration(
                hintText: npfTr('e.g. Zhao Liu (only you see it, to tell people apart)'),
                hintStyle: npfText(14, color: p.muted),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: p.input)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: p.primary, width: 1.5)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final r in data.resources) _pickRow(p, r),
          const SizedBox(height: 8),
          Row(children: [
            Text(npfTr('How long they may use it'), style: npfText(13, color: p.text2)),
            const SizedBox(width: 10),
            for (final t in [(0, 'Always'), (30, '30 days'), (7, '7 days')]) ...[
              NpfPill(npfTr(t.$2),
                  on: term == t.$1, onTap: () => setState(() => term = t.$1)),
              const SizedBox(width: 6),
            ],
          ]),
          const SizedBox(height: 12),
          Text(
              npfTr('A picked service is view-only by default; light up more features to give more. "How long" counts from the day they connect and removes them automatically, e.g. 30 days for a contractor.'),
              style: npfText(12, color: p.text3, height: 1.5)),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: npfText(12, color: p.red)),
          ],
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            NpfButton(npfTr('Cancel'),
                height: 40, radius: 10, onTap: () => Navigator.of(context).pop()),
            const SizedBox(width: 10),
            NpfButton(npfTr('Create invite code'),
                kind: NpfButtonKind.primary,
                height: 40,
                radius: 10,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                onTap: _grants.isEmpty ? null : _create),
          ]),
        ]);
  }

  Widget _pickRow(NpfPalette p, NpfResource r) {
    final only = r.adminOnly;
    final list = pick[r.name] ?? const <String>[];
    final on = list.isNotEmpty;
    final camera = r.type == 'camera';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: only
            ? null
            : () => setState(() => pick[r.name] = on ? [] : [r.features.first]),
        child: SizedBox(
          height: 36,
          child: Row(children: [
            const SizedBox(width: 4),
            NpfCheck(on, dashed: only),
            const SizedBox(width: 10),
            Expanded(
                child: Text(r.title,
                    style: npfText(14, color: only ? p.muted : p.text))),
            Text(
                only
                    ? npfTr('My devices only, cannot be shared')
                    : on
                        ? npfCapSummary(r, list)
                        : (r.svc.isNotEmpty
                            ? r.svc
                            : (r.isDesktop ? npfTr('This screen') : '')),
                style: npfText(12, color: p.text3)),
          ]),
        ),
      ),
      if (on && r.features.length > 1)
        Padding(
          padding: const EdgeInsets.only(left: 32, bottom: 6),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final f in r.features)
              NpfPill(npfCap(f, camera: camera).short,
                  on: list.contains(f),
                  onTap: () => setState(
                      () => pick[r.name] = npfToggleCap(r.features, list, f))),
          ]),
        ),
    ]);
  }

  Widget _codeStep(NpfPalette p, NpfNewCode c) {
    final now = model.now();
    final left = c.expires == null
        ? null
        : npfLeft(npfTime(c.expires)!.difference(now));
    final valid = left == null
        ? ''
        : (c.uses <= 1
            ? npfTr('Valid for {left} · void after one use', {'left': left})
            : npfTr('Valid for {left} · {uses} use(s)', {'left': left, 'uses': c.uses}));
    final rule = [
      if (valid.isNotEmpty) valid,
      term == 0
          ? npfTr('they may use it always')
          : npfTr('they may use it for {d} days after connecting', {'d': term}),
    ].join(' · ');
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(npfTr('Send the invite code to them'),
              style: npfText(18, weight: w700, color: p.text)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            alignment: Alignment.center,
            decoration:
                BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(10)),
            child: SelectableText(c.code,
                style: npfText(28, weight: w700, color: p.text, spacing: 1)),
          ),
          const SizedBox(height: 14),
          Text(
              [
                npfTr('May use: {what}', {'what': _what(picked)}),
                rule,
                npfTr('Logged in to their account, they type it in "Connect to others" on their computer or phone'),
              ].join('\n'),
              style: npfText(13, color: p.text2, height: 20 / 13)),
          const SizedBox(height: 14),
          Text(npfTr('This code is shown only once; after closing the full code cannot be seen again.'),
              style: npfText(12, color: p.text3)),
          const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            NpfButton(npfTr('Copy'),
                height: 40,
                radius: 10,
                onTap: () => Clipboard.setData(ClipboardData(text: c.code))),
            const SizedBox(width: 10),
            NpfButton(npfTr('Done'),
                kind: NpfButtonKind.primary,
                height: 40,
                radius: 10,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                onTap: () => Navigator.of(context).pop()),
          ]),
        ]);
  }
}
