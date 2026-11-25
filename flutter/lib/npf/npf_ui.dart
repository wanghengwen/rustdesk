// Colours, small widgets and formatting shared by the npf pages (the design
// tokens of the scheme C prototype).

import 'package:flutter/material.dart';

import 'npf_lang.dart';
import 'npf_model.dart';

class NpfPalette {
  final Color bg, surface, surface2, line, line2, lineStrong, input;
  final Color text, text2, text3, muted;
  final Color primary, primaryText, primarySoft, primarySoftLine, info;
  final Color green, greenText, red, redSoft, redSoftLine;
  final Color orange, orangeSoft, orangeLine, relay, relaySoft, relayText;
  final Color warn, newBg, disabled, segment, quotaTrack, scrim;

  const NpfPalette({
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.line,
    required this.line2,
    required this.lineStrong,
    required this.input,
    required this.text,
    required this.text2,
    required this.text3,
    required this.muted,
    required this.primary,
    required this.primaryText,
    required this.primarySoft,
    required this.primarySoftLine,
    required this.info,
    required this.green,
    required this.greenText,
    required this.red,
    required this.redSoft,
    required this.redSoftLine,
    required this.orange,
    required this.orangeSoft,
    required this.orangeLine,
    required this.relay,
    required this.relaySoft,
    required this.relayText,
    required this.warn,
    required this.newBg,
    required this.disabled,
    required this.segment,
    required this.quotaTrack,
    required this.scrim,
  });

  static const light = NpfPalette(
    bg: Color(0xFFF4F6F9),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF8FAFC),
    line: Color(0xFFE3E7ED),
    line2: Color(0xFFEEF1F5),
    lineStrong: Color(0xFFD5DBE3),
    input: Color(0xFFC9D3E3),
    text: Color(0xFF1E2530),
    text2: Color(0xFF3F4753),
    text3: Color(0xFF5B6472),
    muted: Color(0xFF9AA3AF),
    primary: Color(0xFF2563EB),
    primaryText: Color(0xFF1D4ED8),
    primarySoft: Color(0xFFE8F0FE),
    primarySoftLine: Color(0xFFC9D9F8),
    info: Color(0xFFF1F5FD),
    green: Color(0xFF16A34A),
    greenText: Color(0xFF15803D),
    red: Color(0xFFB42318),
    redSoft: Color(0xFFFDECEC),
    redSoftLine: Color(0xFFF3C7C3),
    orange: Color(0xFFC2410C),
    orangeSoft: Color(0xFFFDF1E7),
    orangeLine: Color(0xFFF3D3B8),
    relay: Color(0xFFC2570C),
    relaySoft: Color(0xFFFFEDD5),
    relayText: Color(0xFF9A3412),
    warn: Color(0xFF92400E),
    newBg: Color(0xFFFEF3C7),
    disabled: Color(0xFFEEF1F5),
    segment: Color(0xFFE3E7ED),
    quotaTrack: Color(0xFFF1E3D3),
    scrim: Color(0x6B111827),
  );

  static const dark = NpfPalette(
    bg: Color(0xFF15191F),
    surface: Color(0xFF1E242C),
    surface2: Color(0xFF232A33),
    line: Color(0xFF2E3640),
    line2: Color(0xFF29303A),
    lineStrong: Color(0xFF3A434F),
    input: Color(0xFF46505D),
    text: Color(0xFFE6EAF0),
    text2: Color(0xFFC3CAD4),
    text3: Color(0xFF9AA3AF),
    muted: Color(0xFF6B7480),
    primary: Color(0xFF3B82F6),
    primaryText: Color(0xFF93B4FA),
    primarySoft: Color(0xFF1E2B45),
    primarySoftLine: Color(0xFF2B3D63),
    info: Color(0xFF1C2638),
    green: Color(0xFF22C55E),
    greenText: Color(0xFF4ADE80),
    red: Color(0xFFDC4A3D),
    redSoft: Color(0xFF3A2224),
    redSoftLine: Color(0xFF5A2E2E),
    orange: Color(0xFFF97316),
    orangeSoft: Color(0xFF35251A),
    orangeLine: Color(0xFF5A3A22),
    relay: Color(0xFFF08A3C),
    relaySoft: Color(0xFF3A2A1C),
    relayText: Color(0xFFF5B27A),
    warn: Color(0xFFF5B27A),
    newBg: Color(0xFF3D3214),
    disabled: Color(0xFF29303A),
    segment: Color(0xFF29303A),
    quotaTrack: Color(0xFF3A2E24),
    scrim: Color(0x99000000),
  );

  static NpfPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

TextStyle npfText(double size,
        {FontWeight? weight, Color? color, double? height, double? spacing}) =>
    TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: spacing,
        fontFeatures: const [FontFeature.tabularFigures()]);

const w600 = FontWeight.w600;
const w700 = FontWeight.w700;

enum NpfButtonKind { primary, secondary, danger, dangerSoft, disabled, quiet }

/// A flat button of the prototype.
class NpfButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final NpfButtonKind kind;
  final double height;
  final double fontSize;
  final double radius;
  final EdgeInsets padding;
  final Color? borderColor;
  final Color? textColor;
  final FontWeight? weight;

  const NpfButton(this.label,
      {super.key,
      this.onTap,
      this.kind = NpfButtonKind.secondary,
      this.height = 36,
      this.fontSize = 14,
      this.radius = 8,
      this.padding = const EdgeInsets.symmetric(horizontal: 16),
      this.borderColor,
      this.textColor,
      this.weight});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    final k = onTap == null ? NpfButtonKind.disabled : kind;
    final (bg, fg, side, fw) = switch (k) {
      NpfButtonKind.primary => (p.primary, Colors.white, null, w600),
      NpfButtonKind.secondary => (p.surface, p.text, borderColor ?? p.input, null),
      NpfButtonKind.danger => (p.red, Colors.white, null, w600),
      NpfButtonKind.dangerSoft => (p.redSoft, p.red, null, w600),
      NpfButtonKind.disabled => (p.disabled, p.text3, null, null),
      NpfButtonKind.quiet => (Colors.transparent, p.text, null, null),
    };
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: side == null ? BorderSide.none : BorderSide(color: side)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: height,
          padding: padding,
          child: Center(
            widthFactor: 1,
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: npfText(fontSize,
                    weight: weight ?? fw, color: textColor ?? fg)),
          ),
        ),
      ),
    );
  }
}

class NpfDot extends StatelessWidget {
  final Color color;
  final double size;
  const NpfDot(this.color, {super.key, this.size = 8});

  @override
  Widget build(BuildContext context) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// Three signal bars, [n] of them lit (0 = offline).
class NpfSignalBars extends StatelessWidget {
  final int n;
  final Color? color;
  const NpfSignalBars(this.n, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    Widget bar(double h, bool lit) => Container(
        width: 4,
        height: h,
        margin: const EdgeInsets.only(left: 2),
        decoration: BoxDecoration(
            color: lit ? (color ?? p.primary) : p.lineStrong,
            borderRadius: BorderRadius.circular(1)));
    return Semantics(
      label: '$n/3',
      child: SizedBox(
        height: 14,
        child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [bar(5, n >= 1), bar(9, n >= 2), bar(13, n >= 3)]),
      ),
    );
  }
}

/// The square check box of the prototype; [dashed]: not available.
class NpfCheck extends StatelessWidget {
  final bool on;
  final bool dashed;
  const NpfCheck(this.on, {super.key, this.dashed = false});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: dashed ? p.surface2 : (on ? p.primary : p.surface),
        border: on && !dashed
            ? null
            : Border.all(color: dashed ? p.lineStrong : p.input),
      ),
      child: on
          ? CustomPaint(
              size: const Size(12, 10),
              painter: _CheckPainter(dashed ? p.muted : Colors.white))
          : null,
    );
  }
}

class _CheckPainter extends CustomPainter {
  final Color color;
  const _CheckPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(size.width * 0.05, size.height * 0.55)
      ..lineTo(size.width * 0.38, size.height * 0.9)
      ..lineTo(size.width * 0.95, size.height * 0.1);
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.color != color;
}

/// A round toggle pill (a feature of a service).
class NpfPill extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback? onTap;
  const NpfPill(this.label, {super.key, required this.on, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    return Semantics(
      button: true,
      toggled: on,
      child: Material(
        color: on ? p.primary : p.surface,
        shape: StadiumBorder(side: BorderSide(color: on ? p.primary : p.input)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              widthFactor: 1,
              child: Text(label,
                  style: npfText(13, color: on ? Colors.white : p.text2)),
            ),
          ),
        ),
      ),
    );
  }
}

class NpfSwitch extends StatelessWidget {
  final bool on;
  final VoidCallback? onTap;
  final String? label;
  const NpfSwitch({super.key, required this.on, this.onTap, this.label});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    return Semantics(
      label: label,
      toggled: on,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: 40,
            height: 24,
            padding: const EdgeInsets.all(2),
            alignment: on ? Alignment.centerRight : Alignment.centerLeft,
            decoration: BoxDecoration(
                color: on ? p.primary : p.input,
                borderRadius: BorderRadius.circular(12)),
            child: Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                    color: Colors.white, shape: BoxShape.circle)),
          ),
        ),
      ),
    );
  }
}

/// The "⋯" icon of the prototype.
class NpfMoreIcon extends StatelessWidget {
  final Color color;
  const NpfMoreIcon(this.color, {super.key});

  @override
  Widget build(BuildContext context) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++)
          Container(
              width: 3,
              height: 3,
              margin: const EdgeInsets.symmetric(horizontal: 1.2),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      ]);
}

BoxDecoration npfCard(NpfPalette p, {double radius = 12, Color? color}) =>
    BoxDecoration(
        color: color ?? p.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: p.line));

/// A modal of the prototype: a white box on a dark scrim.
Future<T?> npfShowDialog<T>(BuildContext context,
    {required double width, required WidgetBuilder builder}) {
  final p = NpfPalette.of(context);
  return showDialog<T>(
    context: context,
    barrierColor: p.scrim,
    builder: (ctx) => Dialog(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
          width: width,
          child: SingleChildScrollView(
              padding: const EdgeInsets.all(20), child: builder(ctx))),
    ),
  );
}

// ---------------------------------------------------------------------------
// formatting

String _two(int v) => v.toString().padLeft(2, '0');

/// "1 小时 52 分", "2 小时", "35 分钟".
String npfLeft(Duration d) {
  final m = d.inMinutes;
  if (m >= 60) {
    return m % 60 == 0
        ? npfTr('{h} h', {'h': m ~/ 60})
        : npfTr('{h} h {m} min', {'h': m ~/ 60, 'm': m % 60});
  }
  return npfTr('{m} min', {'m': m < 1 ? 1 : m});
}

/// "00:04:12".
String npfClock(Duration d) =>
    '${_two(d.inHours)}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}';

/// "12 月 8 日" / "Dec 8".
String npfDate(DateTime t) {
  if (NpfLang.zh) return '${t.month} 月 ${t.day} 日';
  const m = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${m[t.month - 1]} ${t.day}';
}

/// "今天 09:12", "昨天 20:14", "11 月 5 日 20:40".
String npfWhen(DateTime t, DateTime now) {
  final hm = '${_two(t.hour)}:${_two(t.minute)}';
  final day = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return npfTr('Today {t}', {'t': hm});
  if (diff == 1) return npfTr('Yesterday {t}', {'t': hm});
  return '${npfDate(t)} $hm';
}

/// "昨天", "10 天前".
String npfAgo(DateTime t, DateTime now) {
  final d = DateTime(now.year, now.month, now.day)
      .difference(DateTime(t.year, t.month, t.day))
      .inDays;
  if (d <= 0) return npfTr('today');
  if (d == 1) return npfTr('yesterday');
  return npfTr('{d} days ago', {'d': d});
}

/// "146 / 200 MiB".
String npfMiB(int bytes) => '${(bytes / (1 << 20)).round()}';

// ---------------------------------------------------------------------------
// quality

/// Signal bars of a link: by round trip time (0 when offline).
int npfBars({required bool online, String? path, int? rttMs}) {
  if (!online) return 0;
  if (rttMs == null) return path == null ? 1 : (path == 'p2p' ? 3 : 2);
  return rttMs <= 50 ? 3 : (rttMs <= 150 ? 2 : 1);
}

String npfQualityWord(int bars) => switch (bars) {
      >= 3 => npfTr('Good'),
      2 => npfTr('Fair'),
      _ => npfTr('Poor'),
    };

String npfPathWord(String? path) =>
    path == 'p2p' ? npfTr('direct') : npfTr('via server');

// ---------------------------------------------------------------------------
// features ("can" names)

class NpfCap {
  final String short; // in cells and pills
  final String long; // in lists
  final String note;
  final bool risky; // a reminder when given
  const NpfCap(this.short, this.long, this.note, {this.risky = false});
}

NpfCap npfCap(String cap, {bool camera = false}) {
  switch (cap) {
    case 'view':
      return camera
          ? NpfCap(npfTr('view'), npfTr('View and listen'), npfTr('Live picture'))
          : NpfCap(npfTr('view'), npfTr('View screen'),
              npfTr('View only, no input'));
    case 'control':
      return NpfCap(npfTr('control'), npfTr('Control keyboard and mouse'),
          npfTr('Includes the clipboard'));
    case 'file':
      return NpfCap(npfTr('file'), npfTr('Transfer files'),
          npfTr('Can send and receive files on your computer'),
          risky: true);
    case 'terminal':
      return NpfCap(npfTr('terminal'), npfTr('Terminal'),
          npfTr('Can run commands on your computer'),
          risky: true);
    case 'ptz':
      return NpfCap(npfTr('ptz'), npfTr('Turn the camera'),
          npfTr('Up, down, left, right, presets'));
    case 'zoom':
      return NpfCap(npfTr('zoom'), npfTr('Zoom'), npfTr('Closer, farther'));
    case 'talk':
      return NpfCap(npfTr('talk'), npfTr('Talk'),
          npfTr('Can speak into your home through the camera'),
          risky: true);
    case 'use':
      return NpfCap(npfTr('Can use'), npfTr('Can use'), '');
  }
  return NpfCap(cap, cap, '');
}

/// The short names joined: "看、控制".
String npfCapList(Iterable<String> caps, {bool camera = false}) =>
    caps.map((c) => npfCap(c, camera: camera).short).join(NpfLang.zh ? '、' : ', ');

/// The long names joined: "看屏幕、控制键盘鼠标".
String npfCapLongList(Iterable<String> caps, {bool camera = false}) => caps
    .map((c) => npfCap(c, camera: camera).long)
    .join(NpfLang.zh ? '、' : ', ');

/// A cell of the sharing table: 不给 / 能用 / 全部 / 看、控制.
String npfCapSummary(NpfResource r, List<String> can) {
  if (can.isEmpty) return npfTr('None');
  if (r.features.length == 1) return npfTr('Can use');
  if (r.features.every(can.contains)) return npfTr('All');
  return npfCapList(r.features.where(can.contains),
      camera: r.type == 'camera');
}

/// Toggles [cap] in [cur]: the first feature is the base (dropping it drops
/// all, adding another adds it); the order follows the resource.
List<String> npfToggleCap(List<String> features, List<String> cur, String cap) {
  final base = features.first;
  if (cur.contains(cap)) {
    return cap == base ? [] : cur.where((c) => c != cap).toList();
  }
  final add = {...cur, cap, base};
  return features.where(add.contains).toList();
}
