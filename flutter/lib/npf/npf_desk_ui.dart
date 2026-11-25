// The session window's toolbar and its panels (npf's docs/design/oudesk-ui.md
// 7): one bar with what is used most on it (the screens, the files, the chat,
// the call), three categories, and a panel a category in place of the
// cascading menus, as wide as the bar and in two columns. Plain widgets: what
// they show and do is given by their caller
// (desktop/widgets/remote_toolbar_npf.dart).
// Always dark: they lie over the remote picture.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'npf_lang.dart';

/// The session page's colours (oudesk-ui.md 4, the phone pages' DeskUi).
class NpfDesk {
  static const panel = Color(0xFF171A21);
  static const raised = Color(0xFF222630);
  static const sunk = Color(0xFF0F1218);
  static const line = Color(0x14FFFFFF);
  static const rule = Color(0x12FFFFFF);
  static const hover = Color(0x0FFFFFFF);
  static const text = Color(0xFFEEF1F6);
  static const dim = Color(0xFFAAB2C0);
  static const idle = Color(0xFFC5CBD6);
  static const accent = Color(0xFF4C8DFF);
  static const accentBg = Color(0x334C8DFF);
  static const accentText = Color(0xFF9CC0FF);
  static const danger = Color(0xFFD93A2F);
  static const dangerText = Color(0xFFFF8A80);
  static const off = Color(0xFF4A5162);
  static const green = Color(0xFF3DDC84);
  static const yellow = Color(0xFFF2A93B);
  static const red = Color(0xFFFF6B5E);
  static const float = Color(0xF0171A21);

  static const edge = Color(0x1FFFFFFF);

  static const double panelWidth = 344; // beside a bar at a side
  static const double panelMin = 600; // two columns need it
  static const double barHeight = 48;
  static const double barWidth = 64; // docked at the left or right edge
  static const double gap = 8; // between the bar and its panel
}

/// The icons: the design's 24 x 24 paths, drawn as lines.
class NpfDeskIcons {
  static const bolt = 'M13 2 4 14h7l-1 8 9-12h-7l1-8z';
  static const cursor = 'M5 3l5.5 16 2.3-6.2L19 10.5 5 3z';
  static const monitor = 'M3 4h18v12H3zM8 20h8M12 16v4';
  static const monitorOff =
      'M3 4h18v12H3zM8 20h8M12 16v4M9.5 7.5l5 5M14.5 7.5l-5 5';
  static const grid = 'M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z';
  static const keyboard =
      'M2 6h20v12H2zM6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10';
  static const lock = 'M6 11h12v9H6zM8 11V8a4 4 0 0 1 8 0v3';
  static const refresh = 'M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7';
  static const shot =
      'M4 8h3l2-3h6l2 3h3v11H4zM12 13m-3 0a3 3 0 1 0 6 0a3 3 0 1 0-6 0';
  static const desktop = 'M3 4h18v12H3zM8 20h8M12 16v4M7 8h4v4H7z';
  static const windows = 'M3 6h12v10H3zM9 10h12v10H9z';
  static const cad = 'M3 6h18v12H3zM7 10h2M11 10h2M15 10h2M8 14h8';
  static const search = 'M11 11m-6 0a6 6 0 1 0 12 0a6 6 0 1 0-12 0M16 16l4 4';
  static const clip = 'M8 4h8v3H8zM6 6H5v15h14V6h-1M9 12h6M9 16h6';
  static const copy = 'M8 8h11v12H8zM5 16V4h10';
  static const key = 'M12 11a4 4 0 1 1-8 0 4 4 0 0 1 8 0zM12 11h9v3M17 11v3';
  static const block =
      'M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 1 0-18 0M5.6 5.6l12.8 12.8';
  static const power = 'M12 3v9M6.3 6.3a8 8 0 1 0 11.4 0';
  static const speaker =
      'M4 9h4l5-4v14l-5-4H4zM16 9a4 4 0 0 1 0 6M18.5 6.5a8 8 0 0 1 0 11';
  static const pin = 'M9 3h6l-1 6 3 3v2H7v-2l3-3-1-6zM12 14v7';
  static const mouse = 'M7 8a5 5 0 0 1 10 0v8a5 5 0 0 1-10 0zM12 7v4';
  static const relative =
      'M12 4v16M4 12h16M9 7l3-3 3 3M9 17l3 3 3-3M7 9l-3 3 3 3M17 9l3 3-3 3';
  static const eye =
      'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12zM12 12m-3 0a3 3 0 1 0 6 0a3 3 0 1 0-6 0';
  static const swap = 'M8 4v16M8 4l-3 3M8 4l3 3M16 20V4M16 20l-3-3M16 20l3-3';
  static const keys = 'M3 9h18v6H3zM7 12h.01M11 12h.01M15 12h.01';
  static const phone =
      'M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2z';
  static const folder = 'M3 6h6l2 2h10v11H3zM9 13h7M13 10l3 3-3 3';
  static const terminal = 'M3 5h18v14H3zM7 10l3 2-3 2M12 15h5';
  static const record =
      'M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 1 0-18 0M12 12m-3.5 0a3.5 3.5 0 1 0 7 0a3.5 3.5 0 1 0-7 0';
  static const resolution = 'M3 5h18v14H3zM7 9h3M7 9v3M17 15h-3M17 15v-3';
  static const sliders = 'M4 7h10M18 7h2M4 17h4M12 17h8M16 5v4M10 15v4';
  static const info =
      'M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 1 0-18 0M12 11v6M12 7.5h.01';
  static const office = 'M3 8h18v11H3zM9 8V5h6v3M3 13h18';
  static const hd =
      'M12 3l2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5z';
  static const game =
      'M7 8h10a4 4 0 0 1 4 4v2a3 3 0 0 1-5.5 1.6L14.5 14h-5l-1 1.6A3 3 0 0 1 3 14v-2a4 4 0 0 1 4-4zM7.5 10.5v3M6 12h3M16 11.5h.01M18 13h.01';
  static const window = 'M3 5h18v14H3zM12 12h7v5h-7z';
  static const fullscreen = 'M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5';
  static const chat = 'M4 5h16v11H9l-5 4z';
  static const camera = 'M3 7h12v10H3zM15 10l6-3v10l-6-3';
  static const tunnel = 'M4 8h6v8H4zM14 8h6v8h-6zM10 12h4';
  static const shield = 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z';
  static const right = 'M9 6l6 6-6 6';
  static const down = 'M6 9l6 6 6-6';
  static const back = 'M15 5l-7 7 7 7';
  static const home = 'M4 11l8-7 8 7v9H4zM10 20v-6h4v6';
  static const recents = 'M5 5h14v14H5z';
  static const plus = 'M12 5v14M5 12h14';
  static const minus = 'M5 12h14';
  static const up = 'M6 15l6-6 6 6';
  static const mic =
      'M12 3a3 3 0 0 1 3 3v5a3 3 0 0 1-6 0V6a3 3 0 0 1 3-3zM6 11a6 6 0 0 0 12 0M12 17v4';
  static const fullscreenExit = 'M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5';
  static const edit = 'M4 20h4L19 9l-4-4L4 16zM13.5 6.5l4 4';
}

/// One of [NpfDeskIcons].
class NpfDeskIcon extends StatelessWidget {
  final String path;
  final double size;
  final Color color;
  final double stroke;
  const NpfDeskIcon(this.path,
      {super.key,
      this.size = 18,
      this.color = NpfDesk.text,
      this.stroke = 1.7});

  @override
  Widget build(BuildContext context) {
    const head = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"';
    return SvgPicture.string(
        '$head fill="none" stroke="#000" stroke-width="$stroke" '
        'stroke-linecap="round" stroke-linejoin="round"><path d="$path"/></svg>',
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn));
  }
}


/// The bar's categories, in its order.
enum NpfDeskCat { control, picture, tools }

String npfDeskCatName(NpfDeskCat c) => switch (c) {
      NpfDeskCat.control => npfTr('Control'),
      NpfDeskCat.picture => npfTr('Picture'),
      NpfDeskCat.tools => npfTr('Tools'),
    };

String _catIcon(NpfDeskCat c) => switch (c) {
      NpfDeskCat.control => NpfDeskIcons.bolt,
      NpfDeskCat.picture => NpfDeskIcons.monitor,
      NpfDeskCat.tools => NpfDeskIcons.grid,
    };

/// Something of the page to click: its hover and press shown on [radius].
class _Tap extends StatelessWidget {
  final VoidCallback? onTap;
  final double radius;
  final Color? color;
  final Widget child;
  const _Tap(
      {required this.onTap, required this.child, this.radius = 10, this.color});

  @override
  Widget build(BuildContext context) => Material(
      color: color ?? Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
          onTap: onTap,
          hoverColor: NpfDesk.hover,
          splashColor: NpfDesk.hover,
          highlightColor: NpfDesk.hover,
          child: child));
}

Widget _tip(String? message, Widget child) => message == null || message.isEmpty
    ? child
    : Tooltip(
        message: message,
        waitDuration: const Duration(milliseconds: 400),
        child: child);

Widget _dot(Color color, [double size = 8]) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle));

/// One of the bar's buttons that act at once: an icon; while a state lasts (a
/// call, the recording) it is tinted in [color] with [label] beside it, and
/// [dot] shows a dot of that colour for the icon. [on]: lit, as an open
/// category is.
class NpfDeskBarAction {
  final String icon;
  final String tip;
  final VoidCallback? onTap;
  final Color? color;
  final Widget? label;
  final bool dot;
  final bool on;
  const NpfDeskBarAction(this.icon, this.tip, this.onTap,
      {this.color, this.label, this.dot = false, this.on = false});
}

/// The toolbar, one row: the grip to drag it by, the connection's pill, the
/// peer's screens, the categories, what acts at once ([actions]), the
/// window's ([window]: full screen, collapse), the end of the session. What
/// lies between the pill and the end scrolls when the window is narrower.
/// Along [axis]: a column at the sides, without the pill and the screens.
class NpfDeskBar extends StatelessWidget {
  final Axis axis;
  final Widget? grip;
  final Widget? leading;
  final List<NpfDeskOption<int>> displays;
  final int? display;
  final ValueChanged<int>? onDisplay;
  final List<NpfDeskCat> cats;
  final NpfDeskCat? open;
  final Map<NpfDeskCat, String> tags;
  final ValueChanged<NpfDeskCat> onCat;
  final List<NpfDeskBarAction> actions;
  final List<NpfDeskBarAction> window;
  final VoidCallback onEnd;

  const NpfDeskBar(
      {super.key,
      this.axis = Axis.horizontal,
      this.grip,
      this.leading,
      this.displays = const [],
      this.display,
      this.onDisplay,
      required this.cats,
      required this.open,
      this.tags = const {},
      required this.onCat,
      this.actions = const [],
      this.window = const [],
      required this.onEnd});

  @override
  Widget build(BuildContext context) {
    final row = axis == Axis.horizontal;
    final rule = Container(
        width: row ? 1 : 20,
        height: row ? 20 : 1,
        margin: row
            ? const EdgeInsets.symmetric(horizontal: 5)
            : const EdgeInsets.symmetric(vertical: 5),
        color: NpfDesk.edge);
    final gap = row ? const SizedBox(width: 3) : const SizedBox(height: 3);
    List<Widget> spaced(Iterable<Widget> v) => [
          for (final w in v) ...[w, gap]
        ]..removeLast();
    final middle = <Widget>[
      if (row && displays.length > 1) ...[
        NpfDeskSegment<int>(
            options: displays,
            value: display,
            onChanged: onDisplay,
            expand: false,
            padding: EdgeInsets.zero,
            leading: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 5),
                child: NpfDeskIcon(NpfDeskIcons.monitor,
                    size: 16, color: NpfDesk.dim))),
        rule,
      ],
      ...spaced(cats.map((c) => _cat(c, row))),
      if (actions.isNotEmpty) ...[rule, ...spaced(actions.map(_action))],
      if (window.isNotEmpty) ...[rule, ...spaced(window.map(_action))],
    ];
    final end = _Tap(
        onTap: onEnd,
        radius: 9,
        color: NpfDesk.danger,
        child: Container(
            height: 36,
            width: row ? null : NpfDesk.barWidth - 12,
            alignment: row ? null : Alignment.center,
            padding: EdgeInsets.symmetric(horizontal: row ? 16 : 4),
            child: Center(
                widthFactor: 1,
                child: Text(npfTr('End'),
                    maxLines: 1,
                    softWrap: false,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)))));
    return Material(
        type: MaterialType.transparency,
        child: Container(
            height: row ? NpfDesk.barHeight : null,
            width: row ? null : NpfDesk.barWidth,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
                color: NpfDesk.float,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: NpfDesk.line),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x73000000),
                      blurRadius: 24,
                      offset: Offset(0, 8))
                ]),
            child: Flex(
                direction: axis,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (grip != null) grip!,
                  if (row && leading != null) ...[leading!, rule],
                  Flexible(
                      child: SingleChildScrollView(
                          scrollDirection: axis,
                          child: Flex(
                              direction: axis,
                              mainAxisSize: MainAxisSize.min,
                              children: middle))),
                  row ? const SizedBox(width: 6) : const SizedBox(height: 6),
                  end,
                ])));
  }

  Widget _cat(NpfDeskCat c, bool row) {
    final on = c == open;
    final color = on ? NpfDesk.accentText : NpfDesk.text;
    final label = Text(npfDeskCatName(c),
        style: TextStyle(
            color: color,
            fontSize: row ? 15 : 12,
            fontWeight: row ? FontWeight.w500 : FontWeight.w400));
    final icon = NpfDeskIcon(_catIcon(c), size: row ? 17 : 18, color: color);
    final tag = tags[c];
    return _Tap(
        onTap: () => onCat(c),
        radius: 9,
        color: on ? NpfDesk.accentBg : null,
        child: row
            ? Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 11),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  icon,
                  const SizedBox(width: 7),
                  label,
                  if (tag != null) ...[
                    const SizedBox(width: 7),
                    Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                            color: NpfDesk.accentBg,
                            borderRadius: BorderRadius.circular(6)),
                        child: Text(tag,
                            style: const TextStyle(
                                color: NpfDesk.accentText, fontSize: 13))),
                  ],
                  const SizedBox(width: 6),
                  const NpfDeskIcon(NpfDeskIcons.down,
                      size: 12, color: NpfDesk.dim, stroke: 2),
                ]))
            : SizedBox(
                width: NpfDesk.barWidth - 12,
                height: 48,
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [icon, const SizedBox(height: 3), label])));
  }

  Widget _action(NpfDeskBarAction a) {
    final state = a.color;
    final fg = state ?? (a.on ? NpfDesk.accentText : NpfDesk.text);
    return _tip(
        a.tip,
        Opacity(
            opacity: a.onTap == null ? 0.4 : 1,
            child: _Tap(
                onTap: a.onTap,
                radius: 9,
                color: state != null
                    ? state.withOpacity(0.16)
                    : a.on
                        ? NpfDesk.accentBg
                        : null,
                child: Container(
                    height: 36,
                    constraints: const BoxConstraints(minWidth: 36),
                    padding: EdgeInsets.symmetric(
                        horizontal: a.label == null ? 0 : 9),
                    child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          a.dot
                              ? _dot(fg, 9)
                              : NpfDeskIcon(a.icon, size: 18, color: fg),
                          if (a.label != null) ...[
                            const SizedBox(width: 6),
                            DefaultTextStyle.merge(
                                style: TextStyle(color: fg, fontSize: 14),
                                child: a.label!),
                          ],
                        ])))));
  }
}

/// A state the collapsed bar still shows (the recording, a call).
class NpfDeskBusy extends StatelessWidget {
  final Widget label;
  final Color color;
  const NpfDeskBusy(this.label, {super.key, required this.color});

  @override
  Widget build(BuildContext context) => Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
          color: color.withOpacity(0.16),
          borderRadius: BorderRadius.circular(11)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _dot(color, 7),
        const SizedBox(width: 5),
        DefaultTextStyle.merge(
            style: const TextStyle(
                color: NpfDesk.text,
                fontSize: 13,
                fontWeight: FontWeight.w400,
                decoration: TextDecoration.none),
            child: label),
      ]));
}

/// The bar collapsed: the grip, the connection's pill, the states that last,
/// and the button that brings the bar back.
class NpfDeskHandle extends StatelessWidget {
  final Axis axis;
  final Widget? grip;
  final Widget? leading;
  final List<Widget> busy;
  final String expandIcon;
  final String expandTip;
  final VoidCallback onExpand;

  const NpfDeskHandle(
      {super.key,
      this.axis = Axis.horizontal,
      this.grip,
      this.leading,
      this.busy = const [],
      this.expandIcon = NpfDeskIcons.down,
      required this.expandTip,
      required this.onExpand});

  @override
  Widget build(BuildContext context) {
    final row = axis == Axis.horizontal;
    final gap = row ? const SizedBox(width: 6) : const SizedBox(height: 6);
    return Material(
        type: MaterialType.transparency,
        child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
                color: NpfDesk.float,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: NpfDesk.line),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 18,
                      offset: Offset(0, 6))
                ]),
            child: Flex(
                direction: axis,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (grip != null) grip!,
                  if (row && leading != null) ...[leading!, gap],
                  if (row)
                    for (final b in busy) ...[b, gap],
                  _tip(
                      expandTip,
                      _Tap(
                          onTap: onExpand,
                          radius: 8,
                          color: NpfDesk.raised,
                          child: SizedBox(
                              width: 28,
                              height: 26,
                              child: Center(
                                  child: NpfDeskIcon(expandIcon,
                                      size: 16, stroke: 1.9))))),
                ])));
  }
}

/// The time since [since], ticking: "05:12", "1:05:12".
class NpfDeskElapsed extends StatefulWidget {
  final DateTime since;
  const NpfDeskElapsed(this.since, {super.key});

  @override
  State<NpfDeskElapsed> createState() => _NpfDeskElapsedState();
}

class _NpfDeskElapsedState extends State<NpfDeskElapsed> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Text(npfDeskElapsed(DateTime.now().difference(widget.since)),
          style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()]));
}

String npfDeskElapsed(Duration d) {
  final s = d.isNegative ? 0 : d.inSeconds;
  String two(int n) => n.toString().padLeft(2, '0');
  final tail = '${two(s ~/ 60 % 60)}:${two(s % 60)}';
  return s >= 3600 ? '${s ~/ 3600}:$tail' : tail;
}

/// Tells [onSize] the size its child was laid out at, after the frame.
class NpfDeskMeasure extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onSize;
  const NpfDeskMeasure({super.key, required this.onSize, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasure(onSize);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderMeasure).onSize = onSize;
}

class _RenderMeasure extends RenderProxyBox {
  ValueChanged<Size> onSize;
  Size? _told;
  _RenderMeasure(this.onSize);

  @override
  void performLayout() {
    super.performLayout();
    final now = size;
    if (now == _told) return;
    _told = now;
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(now));
  }
}

/// A category's panel, [width] wide: [left] and [right] side by side (one
/// under the other when it is narrower than two columns need), scrolling past
/// [maxHeight].
class NpfDeskPanel extends StatelessWidget {
  final double width;
  final List<Widget> left;
  final List<Widget> right;
  final double maxHeight;

  const NpfDeskPanel(
      {super.key,
      this.width = NpfDesk.panelWidth,
      required this.left,
      this.right = const [],
      this.maxHeight = 560});

  @override
  Widget build(BuildContext context) {
    Widget column(List<Widget> v) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: v);
    final two = right.isNotEmpty && width >= NpfDesk.panelMin;
    return Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle.merge(
            style: const TextStyle(
                color: NpfDesk.text, fontSize: 14, fontWeight: FontWeight.w400),
            child: IconTheme.merge(
                data: const IconThemeData(color: NpfDesk.dim, size: 16),
                child: Container(
                    width: width,
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    decoration: BoxDecoration(
                        color: NpfDesk.panel,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: NpfDesk.line),
                        boxShadow: const [
                          BoxShadow(
                              color: Color(0x80000000),
                              blurRadius: 36,
                              offset: Offset(0, 14))
                        ]),
                    clipBehavior: Clip.antiAlias,
                    child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                        child: two
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                    Expanded(child: column(left)),
                                    const SizedBox(width: 12),
                                    Expanded(child: column(right)),
                                  ])
                            : column([...left, ...right]))))));
  }
}

/// The line between a panel's sections.
class NpfDeskRule extends StatelessWidget {
  const NpfDeskRule({super.key});

  @override
  Widget build(BuildContext context) => Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      color: NpfDesk.rule);
}

/// A section's name, with what it is now at the right.
class NpfDeskLabel extends StatelessWidget {
  final String text;
  final String? value;
  const NpfDeskLabel(this.text, {super.key, this.value});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(children: [
        Expanded(
            child: Text(text,
                style: const TextStyle(color: NpfDesk.dim, fontSize: 13))),
        if (value != null)
          Text(value!,
              style: const TextStyle(color: NpfDesk.dim, fontSize: 13)),
      ]));
}

/// A smaller line of explanation.
class NpfDeskNote extends StatelessWidget {
  final String text;
  const NpfDeskNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      child: Text(text,
          style: const TextStyle(
              color: NpfDesk.dim, fontSize: 13, height: 1.45)));
}

class _Switch extends StatelessWidget {
  final bool on;
  final bool enabled;
  const _Switch(this.on, this.enabled);

  @override
  Widget build(BuildContext context) => Opacity(
      opacity: enabled ? 1 : 0.45,
      child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 38,
          height: 22,
          padding: const EdgeInsets.all(2),
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          decoration: BoxDecoration(
              color: on ? NpfDesk.accent : NpfDesk.off,
              borderRadius: BorderRadius.circular(11)),
          child: Container(
              width: 18,
              height: 18,
              decoration: const BoxDecoration(
                  color: Colors.white, shape: BoxShape.circle))));
}

Widget _rowBody(
    {String? icon,
    required Widget label,
    String? note,
    Widget? trailing,
    bool enabled = true,
    bool indent = false,
    Color? color}) {
  return Container(
      constraints: const BoxConstraints(minHeight: 40),
      padding: EdgeInsets.fromLTRB(indent ? 34 : 8, 5, 8, 5),
      child: Row(children: [
        if (icon != null) ...[
          NpfDeskIcon(icon,
              size: 17,
              color: (color ?? NpfDesk.dim).withOpacity(enabled ? 1 : 0.45)),
          const SizedBox(width: 9),
        ],
        Expanded(
            child: Opacity(
                opacity: enabled ? 1 : 0.45,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      color == null
                          ? label
                          : DefaultTextStyle.merge(
                              style: TextStyle(color: color), child: label),
                      if (note != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(note,
                                style: const TextStyle(
                                    color: NpfDesk.dim, fontSize: 12.5))),
                    ]))),
        if (trailing != null) ...[const SizedBox(width: 8), trailing],
      ]));
}

/// A row that is on or off. Without [onChanged] it cannot be changed.
class NpfDeskSwitchRow extends StatelessWidget {
  final String? icon;
  final Widget label;
  final String? note;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool indent;

  const NpfDeskSwitchRow(
      {super.key,
      this.icon,
      required this.label,
      this.note,
      required this.value,
      required this.onChanged,
      this.indent = false});

  @override
  Widget build(BuildContext context) => _Tap(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: _rowBody(
          icon: icon,
          label: label,
          note: note,
          indent: indent,
          enabled: onChanged != null,
          trailing: _Switch(value, onChanged != null)));
}

/// A row that does something: [value] is what it is now, [trailing] replaces
/// the arrow, [danger] is for what cannot be taken back.
class NpfDeskActionRow extends StatelessWidget {
  final String? icon;
  final Widget label;
  final String? note;
  final String? value;
  final Widget? trailing;
  final bool arrow;
  final bool danger;
  final VoidCallback? onTap;

  const NpfDeskActionRow(
      {super.key,
      this.icon,
      required this.label,
      this.note,
      this.value,
      this.trailing,
      this.arrow = false,
      this.danger = false,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tail = <Widget>[
      if (value != null)
        ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(value!,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: NpfDesk.dim, fontSize: 13.5))),
      if (trailing != null) trailing!,
      if (arrow)
        const NpfDeskIcon(NpfDeskIcons.right, size: 15, color: NpfDesk.dim),
    ];
    return _Tap(
        onTap: onTap,
        child: _rowBody(
            icon: icon,
            label: label,
            note: note,
            enabled: onTap != null,
            color: danger ? NpfDesk.dangerText : null,
            trailing: tail.isEmpty
                ? null
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    for (var i = 0; i < tail.length; i++) ...[
                      if (i > 0) const SizedBox(width: 4),
                      tail[i]
                    ]
                  ])));
  }
}

/// One of a set of choices.
class NpfDeskOption<T> {
  final T value;
  final Widget label;
  final bool enabled;
  const NpfDeskOption(this.value, this.label, {this.enabled = true});
}

/// A set of choices side by side, the chosen one lit; they wrap.
class NpfDeskOptions<T> extends StatelessWidget {
  final List<NpfDeskOption<T>> options;
  final T? value;
  final ValueChanged<T> onChanged;

  const NpfDeskOptions(
      {super.key,
      required this.options,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      child: Wrap(spacing: 6, runSpacing: 6, children: [
        for (final o in options)
          Opacity(
              opacity: o.enabled ? 1 : 0.4,
              child: _Tap(
                  radius: 16,
                  color: o.value == value ? NpfDesk.accentBg : NpfDesk.raised,
                  onTap: o.enabled ? () => onChanged(o.value) : null,
                  child: Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 13),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: o.value == value
                                  ? NpfDesk.accent
                                  : Colors.transparent)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        DefaultTextStyle.merge(
                            style: TextStyle(
                                color: o.value == value
                                    ? NpfDesk.text
                                    : NpfDesk.idle,
                                fontSize: 13.5),
                            child: o.label)
                      ])))),
      ]));
}
/// A set of choices in one track, the chosen one lit: over the whole row
/// ([expand]) or as wide as they are (on the bar). Without [onChanged] it
/// cannot be changed.
class NpfDeskSegment<T> extends StatelessWidget {
  final List<NpfDeskOption<T>> options;
  final T? value;
  final ValueChanged<T>? onChanged;
  final Widget? leading;
  final bool expand;
  final EdgeInsets padding;

  const NpfDeskSegment(
      {super.key,
      required this.options,
      required this.value,
      required this.onChanged,
      this.leading,
      this.expand = true,
      this.padding = const EdgeInsets.fromLTRB(8, 2, 8, 6)});

  @override
  Widget build(BuildContext context) {
    Widget option(NpfDeskOption<T> o) {
      final on = o.value == value;
      final can = o.enabled && onChanged != null;
      final w = Opacity(
          opacity: can ? 1 : 0.4,
          child: _Tap(
              radius: 7,
              color: on ? NpfDesk.accentBg : null,
              onTap: can ? () => onChanged!(o.value) : null,
              child: Container(
                  height: 30,
                  constraints: const BoxConstraints(minWidth: 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                      widthFactor: 1,
                      child: DefaultTextStyle.merge(
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: on ? NpfDesk.accentText : NpfDesk.idle,
                              fontSize: 14,
                              fontWeight:
                                  on ? FontWeight.w600 : FontWeight.w400),
                          child: o.label)))));
      return expand ? Expanded(child: w) : w;
    }

    return Padding(
        padding: padding,
        child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
                color: NpfDesk.sunk, borderRadius: BorderRadius.circular(9)),
            child: Row(
                mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                children: [
                  if (leading != null) leading!,
                  for (var i = 0; i < options.length; i++) ...[
                    if (i > 0) const SizedBox(width: 2),
                    option(options[i])
                  ],
                ])));
  }
}

/// A name at the left of what sets it (a [NpfDeskSegment]).
class NpfDeskField extends StatelessWidget {
  final String label;
  final Widget child;
  const NpfDeskField(this.label, this.child, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Row(children: [
        SizedBox(
            width: 42,
            child: Text(label,
                style: const TextStyle(color: NpfDesk.dim, fontSize: 13.5))),
        Expanded(child: child),
      ]));
}

/// A row with a number to step down and up. A side without its callback
/// cannot be stepped.
class NpfDeskStepRow extends StatelessWidget {
  final String? icon;
  final Widget label;
  final String? note;
  final int value;
  final VoidCallback? onLess;
  final VoidCallback? onMore;

  const NpfDeskStepRow(
      {super.key,
      this.icon,
      required this.label,
      this.note,
      required this.value,
      required this.onLess,
      required this.onMore});

  @override
  Widget build(BuildContext context) {
    Widget step(String path, VoidCallback? f) => Opacity(
        opacity: f == null ? 0.4 : 1,
        child: _Tap(
            radius: 7,
            color: NpfDesk.raised,
            onTap: f,
            child: SizedBox(
                width: 30,
                height: 30,
                child: Center(child: NpfDeskIcon(path, size: 14, stroke: 2)))));
    return _rowBody(
        icon: icon,
        label: label,
        note: note,
        trailing: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
                color: NpfDesk.sunk, borderRadius: BorderRadius.circular(9)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              step(NpfDeskIcons.minus, onLess),
              SizedBox(
                  width: 30,
                  child: Text('$value',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 15))),
              step(NpfDeskIcons.plus, onMore),
            ])));
  }
}

/// A row with one of a list to choose: what it is now, and the list under it
/// when it is pressed.
class NpfDeskSelectRow<T> extends StatelessWidget {
  final String? icon;
  final Widget label;
  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T>? onChanged;

  const NpfDeskSelectRow(
      {super.key,
      this.icon,
      required this.label,
      required this.options,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final now = options.where((o) => o.$1 == value).firstOrNull?.$2 ?? '';
    return _rowBody(
        icon: icon,
        label: label,
        trailing: PopupMenuButton<T>(
            enabled: onChanged != null,
            tooltip: '',
            padding: EdgeInsets.zero,
            position: PopupMenuPosition.under,
            color: NpfDesk.raised,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: NpfDesk.edge)),
            onSelected: onChanged,
            itemBuilder: (context) => [
                  for (final o in options)
                    PopupMenuItem<T>(
                        value: o.$1,
                        height: 36,
                        child: Text(o.$2,
                            style: TextStyle(
                                color: o.$1 == value
                                    ? NpfDesk.accentText
                                    : NpfDesk.text,
                                fontSize: 14)))
                ],
            child: Container(
                height: 32,
                constraints: const BoxConstraints(maxWidth: 230),
                padding: const EdgeInsets.fromLTRB(10, 0, 7, 0),
                decoration: BoxDecoration(
                    color: NpfDesk.raised,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: NpfDesk.edge)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Flexible(
                      child: Text(now,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: NpfDesk.text, fontSize: 14))),
                  const SizedBox(width: 6),
                  const NpfDeskIcon(NpfDeskIcons.down,
                      size: 13, color: NpfDesk.dim, stroke: 2),
                ]))));
  }
}

/// A button of a row or a card. [danger] is for what ends something, [tint]
/// for what starts it.
class NpfDeskButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  final bool tint;
  const NpfDeskButton(this.label,
      {super.key, required this.onTap, this.danger = false, this.tint = false});

  @override
  Widget build(BuildContext context) => _Tap(
      radius: 8,
      color: danger
          ? NpfDesk.danger
          : tint
              ? NpfDesk.accentBg
              : NpfDesk.raised,
      onTap: onTap,
      child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Center(
              widthFactor: 1,
              child: Text(label,
                  style: TextStyle(
                      color: danger
                          ? Colors.white
                          : tint
                              ? NpfDesk.accentText
                              : NpfDesk.text,
                      fontSize: 14,
                      fontWeight:
                          danger ? FontWeight.w600 : FontWeight.w400)))));
}

/// A state that lasts, in a card of its [color], with what can be done about
/// it at the right (a call and its hanging up).
class NpfDeskStateCard extends StatelessWidget {
  final Color color;
  final Widget label;
  final List<Widget> actions;
  const NpfDeskStateCard(
      {super.key,
      required this.color,
      required this.label,
      this.actions = const []});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      child: Container(
          constraints: const BoxConstraints(minHeight: 46),
          padding: const EdgeInsets.fromLTRB(12, 7, 7, 7),
          decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            _dot(color),
            const SizedBox(width: 9),
            Expanded(child: label),
            for (final a in actions) ...[const SizedBox(width: 6), a],
          ])));
}

/// One of the smaller buttons under the large ones.
class NpfDeskSmall {
  final String icon;
  final Widget label;
  final VoidCallback? onTap;
  final bool danger;
  const NpfDeskSmall(this.icon, this.label, this.onTap, {this.danger = false});
}

/// The smaller buttons, outlined, side by side; they wrap.
class NpfDeskSmallButtons extends StatelessWidget {
  final List<NpfDeskSmall> buttons;
  const NpfDeskSmallButtons(this.buttons, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final b in buttons)
          Opacity(
              opacity: b.onTap == null ? 0.4 : 1,
              child: _Tap(
                  radius: 9,
                  onTap: b.onTap,
                  child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(color: NpfDesk.edge)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        NpfDeskIcon(b.icon,
                            size: 16,
                            color: b.danger ? NpfDesk.dangerText : NpfDesk.text),
                        const SizedBox(width: 6),
                        DefaultTextStyle.merge(
                            style: TextStyle(
                                color: b.danger
                                    ? NpfDesk.dangerText
                                    : NpfDesk.text,
                                fontSize: 14),
                            child: b.label),
                      ])))),
      ]));
}

/// One of the quick panel's large buttons.
class NpfDeskBig {
  final String icon;
  final String label;
  final VoidCallback? onTap;
  const NpfDeskBig(this.icon, this.label, this.onTap);
}

/// The large buttons, three in a row.
class NpfDeskBigButtons extends StatelessWidget {
  final List<NpfDeskBig> buttons;
  const NpfDeskBigButtons(this.buttons, {super.key});

  @override
  Widget build(BuildContext context) {
    const gap = 6.0;
    final rows = <Widget>[];
    for (var i = 0; i < buttons.length; i += 3) {
      if (i > 0) rows.add(const SizedBox(height: gap));
      rows.add(Row(children: [
        for (var j = i; j < i + 3; j++) ...[
          if (j > i) const SizedBox(width: gap),
          Expanded(
              child: j < buttons.length ? _big(buttons[j]) : const SizedBox()),
        ]
      ]));
    }
    return Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: rows));
  }

  Widget _big(NpfDeskBig b) => Opacity(
      opacity: b.onTap == null ? 0.4 : 1,
      child: _Tap(
          radius: 12,
          color: NpfDesk.raised,
          onTap: b.onTap,
          child: SizedBox(
              height: 62,
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    NpfDeskIcon(b.icon, size: 20),
                    const SizedBox(height: 6),
                    Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(b.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13))),
                  ]))));
}
/// One of the picture's modes: its name over what it sets.
class NpfDeskCard<T> {
  final T value;
  final String name;
  final String line;
  const NpfDeskCard(this.value, this.name, this.line);
}

/// The picture's modes as cards, the chosen one lit (none when it is custom).
class NpfDeskCards<T> extends StatelessWidget {
  final List<NpfDeskCard<T>> cards;
  final T? value;
  final ValueChanged<T> onChanged;

  const NpfDeskCards(
      {super.key,
      required this.cards,
      required this.value,
      required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      child: Row(children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: _card(cards[i])),
        ]
      ]));

  Widget _card(NpfDeskCard<T> c) {
    final on = c.value == value;
    return _Tap(
        radius: 10,
        color: on ? NpfDesk.accentBg : NpfDesk.raised,
        onTap: () => onChanged(c.value),
        child: Container(
            height: 62,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: on ? NpfDesk.accent : Colors.transparent)),
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: on ? NpfDesk.accentText : NpfDesk.text)),
                  const SizedBox(height: 4),
                  Text(c.line,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 13, color: NpfDesk.dim)),
                ])));
  }
}

/// A value to drag: what it is now at the right.
class NpfDeskSlider extends StatelessWidget {
  final String label;
  final String text;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  const NpfDeskSlider(
      {super.key,
      required this.label,
      required this.text,
      required this.value,
      required this.min,
      required this.max,
      this.divisions,
      this.onChanged,
      this.onChangeEnd});

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      child: Row(children: [
        SizedBox(
            width: 52,
            child: Text(label,
                style: const TextStyle(color: NpfDesk.dim, fontSize: 13.5))),
        Expanded(
            child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    activeTrackColor: NpfDesk.accent,
                    inactiveTrackColor: NpfDesk.off,
                    thumbColor: Colors.white,
                    overlayColor: NpfDesk.hover,
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 14),
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 7)),
                child: Slider(
                    value: value.clamp(min, max).toDouble(),
                    min: min,
                    max: max,
                    divisions: divisions,
                    onChanged: onChanged,
                    onChangeEnd: onChangeEnd))),
        SizedBox(
            width: 44,
            child: Text(text,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13.5))),
      ]));
}

/// A state of the session that stays in sight while it lasts (recording, a
/// call, the privacy screen, view only): a dot of [color] and its name.
class NpfDeskChip extends StatelessWidget {
  final String text;
  final Color color;
  const NpfDeskChip(this.text, {super.key, this.color = NpfDesk.accent});

  @override
  Widget build(BuildContext context) => Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
          color: NpfDesk.float,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: NpfDesk.line)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(text,
            style: const TextStyle(
                color: NpfDesk.text,
                fontSize: 13,
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w400)),
      ]));
}

/// The chips of the session's states, side by side.
class NpfDeskChips extends StatelessWidget {
  final List<NpfDeskChip> chips;
  const NpfDeskChips(this.chips, {super.key});

  @override
  Widget build(BuildContext context) => Material(
      type: MaterialType.transparency,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < chips.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          chips[i]
        ]
      ]));
}
