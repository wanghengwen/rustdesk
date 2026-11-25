// The session window's quality pill (prototype Session, scheme C: signal bars
// and latency instead of blue / orange for direct / relay) and its popover.

import 'package:flutter/material.dart';

import 'npf_lang.dart';
import 'npf_model.dart';
import 'npf_ui.dart';

/// What the pill shows: RustDesk's quality status plus the npf path.
class NpfSessionQuality {
  final int? rttMs;
  final double? kbps;
  final String? fps;
  final double? lossPct; // not reported by RustDesk yet
  final String? codec;
  final String? path; // p2p | relay | ws_relay | null
  final NpfQuota? quota;

  const NpfSessionQuality(
      {this.rttMs,
      this.kbps,
      this.fps,
      this.lossPct,
      this.codec,
      this.path,
      this.quota});

  /// From RustDesk's `update_quality_status` strings ("123.45kB/s", "32").
  factory NpfSessionQuality.fromRustDesk(
      {String? speed,
      String? delay,
      String? fps,
      String? codecFormat,
      String? path,
      int? npfRttMs,
      NpfQuota? quota}) {
    double? kbps;
    final m = RegExp(r'([\d.]+)\s*([kKmM]?)B/s').firstMatch(speed ?? '');
    if (m != null) {
      final v = double.tryParse(m.group(1)!) ?? 0;
      kbps = v * 8 * (m.group(2)!.toLowerCase() == 'm' ? 1024 : 1);
    }
    final rtt = npfRttMs ??
        int.tryParse(RegExp(r'\d+').firstMatch(delay ?? '')?.group(0) ?? '');
    final codec = switch (codecFormat?.toUpperCase()) {
      'H264' => 'H.264',
      'H265' => 'H.265',
      null || '' => null,
      final c => c,
    };
    return NpfSessionQuality(
        rttMs: rtt,
        kbps: kbps,
        fps: fps?.split(' ').first,
        codec: codec,
        path: path,
        quota: quota);
  }

  bool get relay => path == 'relay' || path == 'ws_relay';
  int get bars => npfBars(online: true, path: path, rttMs: rttMs);

  String get rttText => rttMs == null ? '—' : '$rttMs ms';
  String get rateText => kbps == null
      ? '—'
      : kbps! >= 1000
          ? '${(kbps! / 1000).toStringAsFixed(1)} Mbps'
          : '${kbps!.round()} kbps';

  String get pathLabel => switch (path) {
        'p2p' => npfTr('Direct (peer to peer)'),
        'ws_relay' => npfTr('Relay (via the platform server, WebSocket)'),
        _ => npfTr('Relay (via the platform server)'),
      };
}

/// The pill in the toolbar; tapping it opens [NpfQualityPopover].
class NpfQualityPill extends StatelessWidget {
  /// The pill keeps the width of a wide reading, so the bar does not move as
  /// the numbers change.
  static double _widest(BuildContext context, TextStyle style) {
    final painter = TextPainter(
        text: TextSpan(
            text: '888 ms · 88.8 Mbps',
            style: DefaultTextStyle.of(context).style.merge(style)),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context))
      ..layout();
    final width = painter.width.ceilToDouble();
    painter.dispose();
    return width;
  }

  final NpfSessionQuality q;
  final VoidCallback? onTap;
  final bool open;

  const NpfQualityPill(
      {super.key, required this.q, this.onTap, this.open = false});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    final text = q.rttMs == null && q.kbps == null
        ? npfTr('Measuring…')
        : [q.rttText, if (q.kbps != null) q.rateText].join(' · ');
    final style = npfText(14, weight: w600, color: p.text);
    return Tooltip(
      message: npfTr('Connection quality'),
      child: Material(
        color: open ? p.primarySoft : p.disabled,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              NpfSignalBars(q.bars),
              const SizedBox(width: 7),
              ConstrainedBox(
                  constraints: BoxConstraints(minWidth: _widest(context, style)),
                  child: Text(text, style: style)),
            ]),
          ),
        ),
      ),
    );
  }
}

class NpfQualityPopover extends StatelessWidget {
  final NpfSessionQuality q;
  final VoidCallback? onUpgrade;

  const NpfQualityPopover({super.key, required this.q, this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    Widget stat(String k, String v) => Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration:
              BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k, style: npfText(12, color: p.text3)),
            const SizedBox(height: 2),
            Text(v, style: npfText(15, weight: w600, color: p.text)),
          ]),
        );
    final third = q.lossPct != null
        ? stat(npfTr('Frame loss'), '${q.lossPct!.toStringAsFixed(1)}%')
        : stat(npfTr('Frame rate'), q.fps == null ? '—' : '${q.fps} fps');
    final quota = q.quota;
    return Container(
      width: 340,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Color(0x4D000000), blurRadius: 30, offset: Offset(0, 10))
        ],
      ),
      child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: Text(npfTr('Connection quality'),
                    style: npfText(14, weight: w700, color: p.text)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: p.bg, borderRadius: BorderRadius.circular(999)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  NpfSignalBars(q.bars),
                  const SizedBox(width: 6),
                  Text(q.pathLabel, style: npfText(12, color: p.text2)),
                ]),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: stat(npfTr('Round trip'), q.rttText)),
              const SizedBox(width: 10),
              Expanded(child: stat(npfTr('Bitrate'), q.rateText)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: third),
              const SizedBox(width: 10),
              Expanded(child: stat(npfTr('Codec'), q.codec ?? '—')),
            ]),
            const SizedBox(height: 12),
            Text(
                q.relay
                    ? npfTr(
                        'Without a direct path the platform relays the traffic, still end-to-end encrypted. Relay traffic counts against your account; it switches back once direct works again.')
                    : npfTr(
                        'The two computers are connected directly, without a server and without counting traffic. When the network gets worse only late frames are dropped, nothing stalls, and the picture gets less sharp.'),
                style: npfText(12, color: p.text2, height: 1.5)),
            if (q.relay && quota != null && quota.limit > 0) ...[
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: Text(npfTr('Relay quota this month'),
                        style: npfText(12, color: p.text2))),
                Text('${npfMiB(quota.used)} / ${npfMiB(quota.limit)} MiB',
                    style: npfText(12, color: p.text2)),
              ]),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                    value: quota.ratio,
                    minHeight: 6,
                    backgroundColor: p.quotaTrack,
                    color: p.relay),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  onTap: onUpgrade,
                  child: Text(npfTr('Upgrade plan'),
                      style: npfText(12, color: p.primaryText)),
                ),
              ),
            ],
          ]),
    );
  }
}

/// The pill with its popover, for the session toolbar.
class NpfQualityButton extends StatefulWidget {
  final NpfSessionQuality Function() quality;
  final Listenable listenable;
  final VoidCallback? onUpgrade;

  const NpfQualityButton(
      {super.key,
      required this.quality,
      required this.listenable,
      this.onUpgrade});

  @override
  State<NpfQualityButton> createState() => _NpfQualityButtonState();
}

class _NpfQualityButtonState extends State<NpfQualityButton> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.listenable,
      builder: (context, _) {
        final q = widget.quality();
        return MenuAnchor(
          controller: _menu,
          alignmentOffset: const Offset(0, 8),
          style: const MenuStyle(
            padding: WidgetStatePropertyAll(EdgeInsets.zero),
            backgroundColor: WidgetStatePropertyAll(Colors.transparent),
            elevation: WidgetStatePropertyAll(0),
            shadowColor: WidgetStatePropertyAll(Colors.transparent),
            surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
          ),
          menuChildren: [NpfQualityPopover(q: q, onUpgrade: widget.onUpgrade)],
          builder: (context, menu, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: NpfQualityPill(
                q: q,
                open: menu.isOpen,
                onTap: () => menu.isOpen ? menu.close() : menu.open()),
          ),
        );
      },
    );
  }
}
