// The session toolbar as npf's design has it (npf's docs/design/oudesk-ui.md
// 7): one bar with what is used most on it (the screens, the files, the chat,
// the call), three categories (control, picture, tools), a panel a category in
// place of the cascading menus, and the chips of the session's states. It
// stays until it is collapsed; collapsed it is a small handle that still shows
// the connection, the recording and the call. What the rows do is RustDesk's
// own: the lists of common/widgets/toolbar.dart and this library's menus,
// shown another way. The widgets themselves are lib/npf/npf_desk_ui.dart.

part of 'remote_toolbar.dart';

/// RustDesk's own widgets inside the panels (the grip, dialogs' triggers)
/// take the dark theme: the bar and the panels are dark over the picture.
ThemeData _npfDark() => MyTheme.darkTheme.copyWith(
    textTheme: MyTheme.darkTheme.textTheme
        .apply(fontFamily: _npfFont, fontFamilyFallback: _npfFontFallback),
    menuBarTheme: MenuBarThemeData(
        style: MenuStyle(
            backgroundColor: const MaterialStatePropertyAll(NpfDesk.panel),
            padding: const MaterialStatePropertyAll(EdgeInsets.zero),
            elevation: const MaterialStatePropertyAll(0),
            shape: const MaterialStatePropertyAll(BeveledRectangleBorder()))),
    iconTheme: const IconThemeData(color: NpfDesk.idle));

// One face for the Chinese and the Latin on Windows: Segoe UI with the
// system's fallback for the Chinese mixes two faces of different sizes.
final String? _npfFont = isWindows ? 'Microsoft YaHei UI' : null;
final List<String>? _npfFontFallback =
    isWindows ? const ['Microsoft YaHei', 'Segoe UI'] : null;

/// The bar's and the panels' text in [_npfFont], also where no Material
/// between them and the session's page sets it from the theme.
Widget _npfText(Widget child) => _npfFont == null
    ? child
    : DefaultTextStyle.merge(
        style: TextStyle(
            fontFamily: _npfFont, fontFamilyFallback: _npfFontFallback),
        child: child);

/// Counts what a panel changed that the bar shows too (the picture's mode,
/// the screens each in a window).
final _npfTick = 0.obs;

// when the recording and the call began, for their clocks: the bar is built
// anew each time it is collapsed and shown again
final _npfRecSince = Expando<DateTime>();
final _npfCallSince = Expando<DateTime>();

DateTime? _npfSince(Expando<DateTime> since, Object of, bool on) {
  if (!on) {
    since[of] = null;
    return null;
  }
  return since[of] ??= DateTime.now();
}

/// The picture as it is asked of the peer now, and the codecs both sides have.
Future<(NpfPicture, Set<String>)> _npfReadPicture(SessionID sid) async {
  final codecs = NpfPictureModes.parseCodecs(
      await bind.sessionAlternativeCodecs(sessionId: sid));
  final fps = int.tryParse(
      await bind.sessionGetOption(sessionId: sid, arg: 'custom-fps') ?? '');
  final codec =
      await bind.sessionGetOption(sessionId: sid, arg: kOptionCodecPreference) ??
          '';
  final picture = NpfPicture(
      quality: await bind.sessionGetImageQuality(sessionId: sid) ??
          kRemoteImageQualityBalanced,
      fps: fps == null || fps <= 0 ? 30 : fps,
      codec: codec.isEmpty ? 'auto' : codec,
      i444: bind.sessionGetToggleOptionSync(sessionId: sid, arg: 'i444'));
  return (picture, codecs);
}

bool _npfSeparate(FFI ffi) =>
    bind.sessionGetDisplaysAsIndividualWindows(sessionId: ffi.sessionId) == 'Y';

/// The peer's screens to choose from: none when it has one, or the privacy
/// screen keeps it. "All" only where they are shown in one window.
List<NpfDeskOption<int>> _npfDisplayOptions(String id, FFI ffi,
    {bool long = false}) {
  final pi = ffi.ffiModel.pi;
  final privacy = PrivacyModeState.find(id);
  if (pi.displaysCount.value < 2 ||
      !(privacy.isEmpty || allowDisplaySwitchInPrivacyMode(pi, privacy.value))) {
    return [];
  }
  final n = pi.displays.length;
  return [
    for (var i = 0; i < n; i++)
      NpfDeskOption(
          i,
          Text(long && n <= 2
              ? npfTr('Screen {n}', {'n': i + 1})
              : '${i + 1}')),
    if (!isWeb && pi.isSupportMultiDisplay && !_npfSeparate(ffi))
      NpfDeskOption(kAllDisplayValue, Text(npfTr('All'))),
  ];
}

void _npfShowDisplay(String id, FFI ffi, int i) {
  final pi = ffi.ffiModel.pi;
  _menuDismissCallback(ffi);
  if (CurrentDisplayState.find(id).value == i) return;
  if (pi.isSupportMultiDisplay && _npfSeparate(ffi)) {
    openMonitorInNewTabOrWindow(i, ffi.id, pi);
  } else {
    openMonitorInTheSameTab(i, ffi, pi, updateCursorPos: true);
  }
}

/// Another window to the same peer: its files, a terminal, its camera.
void _npfOpen(BuildContext context, String id, FFI ffi,
    {bool file = false, bool camera = false, bool terminal = false}) {
  final sid = ffi.sessionId;
  connect(context, id,
      loginMethod: bind.sessionGetCommonSync(
              sessionId: sid, key: 'login_method', param: '') ??
          '',
      isFileTransfer: file,
      isViewCamera: camera,
      isTerminal: terminal,
      connToken: bind.sessionGetConnToken(sessionId: sid));
}

void _npfChat(FFI ffi) {
  ffi.chatModel.changeCurrentKey(MessageKey(ffi.id, ChatModel.clientModeID));
  ffi.chatModel.toggleChatOverlay();
}

extension _NpfToolbar on _RemoteToolbarState {
  void _npfMeasured(Size s) {
    if (_dragging.isFalse && _toolbarSize.value != s) _toolbarSize.value = s;
  }

  EdgeInsets _npfInset(_ToolbarEdge edge, double h, double v) => switch (edge) {
        _ToolbarEdge.top => EdgeInsets.only(top: v),
        _ToolbarEdge.bottom => EdgeInsets.only(bottom: v),
        _ToolbarEdge.left => EdgeInsets.only(left: h),
        _ToolbarEdge.right => EdgeInsets.only(right: h),
      };

  /// The grip to drag the bar by: RustDesk's own, without its buttons.
  Widget _npfGrip(_ToolbarEdge edge, bool isHorizontal) => MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: SizedBox(
          width: isHorizontal ? 22 : null,
          height: isHorizontal ? null : 22,
          // the factors: off the bar (the collapsed handle) nothing bounds
          // the grip across, and a plain Center would fill the window
          child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: _DraggableShowHide(
                  id: widget.id,
                  ffi: widget.ffi,
                  sessionId: widget.ffi.sessionId,
                  dragging: _dragging,
                  fraction: _fraction,
                  edge: _edge,
                  previewEdge: _previewEdge,
                  previewFraction: _previewFraction,
                  toolbarSize: _toolbarSize,
                  markDragEpoch: _markToolbarDragEpoch,
                  syncDockingOptionsAfterDragIfNeeded:
                      _syncDockingOptionsAfterDragIfNeeded,
                  isHorizontal: isHorizontal,
                  multiEdgeEnabled: _multiEdgeEnabled.value,
                  toolbarState: widget.state,
                  setFullscreen: _setFullscreen,
                  setMinimize: _minimize,
                  borderRadius: BorderRadius.zero,
                  gripOnly: true))));

  /// A little off its edge: the bar floats over the picture.
  Widget _npfFloat(_ToolbarEdge edge, Widget child) => Theme(
      data: _npfDark(),
      child: NpfDeskMeasure(
          onSize: _npfMeasured,
          child: Padding(
              padding: _npfInset(edge, 6, 6), child: _npfText(child))));

  Widget _npfBuildToolbar(
          BuildContext context, _ToolbarEdge edge, bool isHorizontal) =>
      _npfFloat(
          edge,
          _NpfBar(
              id: widget.id,
              ffi: widget.ffi,
              axis: isHorizontal ? Axis.horizontal : Axis.vertical,
              grip: _npfGrip(edge, isHorizontal),
              open: _npfPanel,
              setFullscreen: _setFullscreen,
              minimize: _minimize,
              collapseIcon: switch (edge) {
                _ToolbarEdge.top => NpfDeskIcons.up,
                _ToolbarEdge.bottom => NpfDeskIcons.down,
                _ToolbarEdge.left => NpfDeskIcons.back,
                _ToolbarEdge.right => NpfDeskIcons.right,
              },
              collapse: () {
                _npfPanel.value = null;
                widget.state.switchCollapse(widget.ffi.sessionId);
              }));

  /// The bar collapsed.
  Widget _npfBuildHandle(
      BuildContext context, _ToolbarEdge edge, bool isHorizontal) {
    final ffi = widget.ffi;
    return _npfFloat(
        edge,
        AnimatedBuilder(
            animation: Listenable.merge([ffi.recordingModel, ffi.ffiModel]),
            builder: (context, _) => Obx(() {
                  final call = ffi.chatModel.voiceCallStatus.value;
                  final rec = _npfSince(_npfRecSince, ffi.recordingModel,
                      ffi.recordingModel.start);
                  final talk = _npfSince(_npfCallSince, ffi.chatModel,
                      call == VoiceCallStatus.connected);
                  Widget timed(String name, DateTime since) =>
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(name),
                        const SizedBox(width: 5),
                        NpfDeskElapsed(since),
                      ]);
                  return NpfDeskHandle(
                      axis: isHorizontal ? Axis.horizontal : Axis.vertical,
                      grip: _npfGrip(edge, isHorizontal),
                      leading: npfQualityItem(ffi),
                      busy: [
                        // clicks and keys are not sent: easy to miss with
                        // the bar collapsed, and it is kept for the peer
                        if (ffi.ffiModel.viewOnly)
                          NpfDeskBusy(Text(npfTr('View only')),
                              color: NpfDesk.accent),
                        if (rec != null)
                          NpfDeskBusy(timed(npfTr('Recording'), rec),
                              color: NpfDesk.red),
                        if (call == VoiceCallStatus.waitingForResponse)
                          NpfDeskBusy(Text(npfTr('Calling')),
                              color: NpfDesk.yellow),
                        if (talk != null)
                          NpfDeskBusy(timed(npfTr('In a call'), talk),
                              color: NpfDesk.green),
                      ],
                      expandIcon: switch (edge) {
                        _ToolbarEdge.top => NpfDeskIcons.down,
                        _ToolbarEdge.bottom => NpfDeskIcons.up,
                        _ToolbarEdge.left => NpfDeskIcons.right,
                        _ToolbarEdge.right => NpfDeskIcons.back,
                      },
                      expandTip: translate('Show Toolbar'),
                      onExpand: () =>
                          widget.state.switchCollapse(ffi.sessionId));
                })));
  }

  /// Under the bar: while a panel is open, a press on the picture closes it
  /// and is not sent to the peer.
  List<Widget> _npfUnder() => [
        if (_npfPanel.value != null && collapse.isFalse)
          Positioned.fill(
              child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => _npfPanel.value = null)),
      ];

  /// Over the bar: the states' chips and the open panel, at the bar's place
  /// along its edge. The panel is as wide as the bar.
  List<Widget> _npfOver(BuildContext context, _ToolbarEdge edge) {
    final cat = _npfPanel.value;
    if (cat != null && (collapse.isTrue || _dragging.isTrue)) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _npfPanel.value = null);
    }
    final open = cat != null && collapse.isFalse && _dragging.isFalse;
    final at = _alignmentForEdge(edge, _fraction.value);
    final size = _toolbarSize.value;
    final horizontal = _isHorizontalEdge(edge);
    return [
      if (!open)
        IgnorePointer(
            child: Align(
                alignment: horizontal ? at : Alignment.topCenter,
                child: Padding(
                    padding: horizontal
                        ? _npfInset(edge, 0, (size?.height ?? 0) + 6)
                        : const EdgeInsets.only(top: 8),
                    child: _npfText(_NpfChips(id: widget.id, ffi: widget.ffi))))),
      if (open)
        LayoutBuilder(builder: (context, box) {
          final across = (size?.width ?? NpfDesk.barWidth + 6) + NpfDesk.gap;
          final along = (size?.height ?? NpfDesk.barHeight + 6) + NpfDesk.gap;
          final width = horizontal
              ? (size?.width ?? NpfDesk.panelMin)
                  .clamp(NpfDesk.panelMin, 980.0)
                  .clamp(280.0, box.maxWidth > 296 ? box.maxWidth - 16 : 280.0)
                  .toDouble()
              : NpfDesk.panelWidth;
          return Align(
              alignment: at,
              child: Padding(
                  padding: _npfInset(edge, across, along),
                  child: Theme(
                      data: _npfDark(),
                      child: _npfText(_NpfPanel(
                          key: ValueKey(cat),
                          cat: cat,
                          id: widget.id,
                          ffi: widget.ffi,
                          setFullscreen: _setFullscreen,
                          close: () => _npfPanel.value = null,
                          width: width,
                          maxHeight:
                              (box.maxHeight - (horizontal ? along : 0) - 16)
                                  .clamp(160.0, 640.0)
                                  .toDouble())))));
        }),
    ];
  }
}

/// The bar, with what it shows of the session: the screens, the picture's
/// mode, the call, the recording.
class _NpfBar extends StatefulWidget {
  final String id;
  final FFI ffi;
  final Axis axis;
  final Widget grip;
  final Rxn<NpfDeskCat> open;
  final Function(bool) setFullscreen;
  final VoidCallback minimize;
  final String collapseIcon;
  final VoidCallback collapse;

  const _NpfBar(
      {required this.id,
      required this.ffi,
      required this.axis,
      required this.grip,
      required this.open,
      required this.setFullscreen,
      required this.minimize,
      required this.collapseIcon,
      required this.collapse});

  @override
  State<_NpfBar> createState() => _NpfBarState();
}

class _NpfBarState extends State<_NpfBar> {
  String? _mode;
  late final Worker _onTick;
  late final Worker _onOpen;

  FFI get ffi => widget.ffi;
  SessionID get sid => widget.ffi.sessionId;

  @override
  void initState() {
    super.initState();
    _onTick = ever(_npfTick, (_) => _readMode());
    // and with each panel: the codecs both sides have are known only once
    // the peer has answered
    _onOpen = ever(widget.open, (_) => _readMode());
    _readMode();
  }

  @override
  void dispose() {
    _onTick.dispose();
    _onOpen.dispose();
    super.dispose();
  }

  Future<void> _readMode() async {
    try {
      final (picture, codecs) = await _npfReadPicture(sid);
      if (!mounted) return;
      setState(() => _mode =
          NpfPictureModes.modeName(NpfPictureModes.of(picture, codecs)));
    } catch (e) {
      debugPrint('npf bar: the picture: $e');
    }
  }

  Future<void> _end() async {
    widget.open.value = null;
    if (await showConnEndAuditDialogCloseCanceled(ffi: ffi)) return;
    closeConnection(id: widget.id);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.id;
    final row = widget.axis == Axis.horizontal;
    void leave(VoidCallback f) {
      widget.open.value = null;
      f();
    }

    return AnimatedBuilder(
        animation: ffi.recordingModel,
        builder: (context, _) => Obx(() {
              _npfTick.value;
              final call = ffi.chatModel.voiceCallStatus.value;
              final full = stateGlobal.fullscreen.value;
              final rec = _npfSince(_npfRecSince, ffi.recordingModel,
                  ffi.recordingModel.start);
              _npfSince(_npfCallSince, ffi.chatModel,
                  call == VoiceCallStatus.connected);
              hangUp() => bind.sessionCloseVoiceCall(sessionId: sid);
              return NpfDeskBar(
                  axis: widget.axis,
                  grip: widget.grip,
                  leading: npfQualityItem(ffi),
                  displays: _npfDisplayOptions(id, ffi),
                  display: CurrentDisplayState.find(id).value,
                  onDisplay: (i) => leave(() => _npfShowDisplay(id, ffi, i)),
                  cats: NpfDeskCat.values,
                  open: widget.open.value,
                  tags: {if (_mode != null) NpfDeskCat.picture: _mode!},
                  onCat: (c) =>
                      widget.open.value = widget.open.value == c ? null : c,
                  actions: [
                    if (ffi.connType == ConnType.defaultConn && isDesktop)
                      NpfDeskBarAction(
                          NpfDeskIcons.folder,
                          translate('Transfer file'),
                          () => leave(
                              () => _npfOpen(context, id, ffi, file: true))),
                    NpfDeskBarAction(NpfDeskIcons.chat, translate('Text chat'),
                        () => leave(() => _npfChat(ffi))),
                    if (!isWeb)
                      switch (call) {
                        VoiceCallStatus.waitingForResponse => NpfDeskBarAction(
                            NpfDeskIcons.phone,
                            npfTr('Calling… click to cancel'),
                            hangUp,
                            color: NpfDesk.yellow),
                        VoiceCallStatus.connected => NpfDeskBarAction(
                            NpfDeskIcons.phone,
                            npfTr('In a call · click to hang up'),
                            hangUp,
                            color: NpfDesk.green),
                        _ => NpfDeskBarAction(
                            NpfDeskIcons.phone,
                            translate('Voice call'),
                            () => bind.sessionRequestVoiceCall(sessionId: sid)),
                      },
                    if (rec != null)
                      NpfDeskBarAction(
                          NpfDeskIcons.record,
                          npfTr('Recording · click to stop'),
                          ffi.recordingModel.toggle,
                          color: NpfDesk.red,
                          dot: row,
                          label: row ? NpfDeskElapsed(rec) : null),
                  ],
                  window: [
                    NpfDeskBarAction(
                        full
                            ? NpfDeskIcons.fullscreenExit
                            : NpfDeskIcons.fullscreen,
                        translate(full ? 'Exit Fullscreen' : 'Fullscreen'),
                        () => widget.setFullscreen(!full),
                        on: full),
                    if (full && !isMacOS && !isWebDesktop)
                      NpfDeskBarAction(NpfDeskIcons.minus,
                          translate('Minimize'), widget.minimize),
                    NpfDeskBarAction(widget.collapseIcon,
                        translate('Hide Toolbar'), widget.collapse),
                  ],
                  onEnd: _end);
            }));
  }
}

/// The session's states that stay in sight while they last. The recording and
/// the call are on the bar itself.
class _NpfChips extends StatelessWidget {
  final String id;
  final FFI ffi;
  const _NpfChips({required this.id, required this.ffi});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: ffi.ffiModel,
      builder: (context, _) => Obx(() {
            final chips = [
              if (PrivacyModeState.find(id).isNotEmpty)
                NpfDeskChip(npfTr('Privacy screen')),
              if (BlockInputState.find(id).isTrue)
                NpfDeskChip(npfTr('Their input is blocked'),
                    color: NpfDesk.yellow),
              if (ffi.ffiModel.viewOnly) NpfDeskChip(npfTr('View only')),
            ];
            return chips.isEmpty ? const SizedBox.shrink() : NpfDeskChips(chips);
          }));
}

/// What a panel shows, read from the session when it opens and after each
/// change (RustDesk's lists carry the values of the moment they were made).
class _NpfData {
  List<TTextMenu> controls = [];
  List<TToggleMenu> display = [];
  List<TToggleMenu> cursor = [];
  List<TToggleMenu> keyboard = [];
  List<TToggleMenu> privacy = [];
  List<TRadioMenu<String>> viewStyle = [];
  NpfPicture? picture;
  Set<String> codecs = {};
  String scrollStyle = '';
  int edgeThickness = 0;
  bool canAdjust = false;
  String keyboardMode = '';
  List<String> speakers = [];
  String speaker = '';
}

class _NpfPanel extends StatefulWidget {
  final NpfDeskCat cat;
  final String id;
  final FFI ffi;
  final Function(bool) setFullscreen;
  final VoidCallback close;
  final double width;
  final double maxHeight;

  const _NpfPanel(
      {super.key,
      required this.cat,
      required this.id,
      required this.ffi,
      required this.setFullscreen,
      required this.close,
      required this.width,
      required this.maxHeight});

  @override
  State<_NpfPanel> createState() => _NpfPanelState();
}

class _NpfPanelState extends State<_NpfPanel> {
  _NpfData? _d;
  // a switch just changed: its new value until the session is read again
  final _set = <Object, bool>{};
  // the virtual screens just asked for, until the peer says what it has
  int? _virtual;
  int _serial = 0;

  late final ScreenAdjustor _adjustor = ScreenAdjustor(
      id: widget.id,
      ffi: widget.ffi,
      cbExitFullscreen: () => widget.setFullscreen(false));

  String get id => widget.id;
  FFI get ffi => widget.ffi;
  SessionID get sid => widget.ffi.sessionId;
  PeerInfo get pi => widget.ffi.ffiModel.pi;
  FfiModel get ffiModel => widget.ffi.ffiModel;
  bool get defaultConn => widget.ffi.connType == ConnType.defaultConn;
  bool get canInput => defaultConn && ffiModel.keyboard;
  bool get canType => canInput && !ffiModel.viewOnly;

  @override
  void initState() {
    super.initState();
    // not in initState itself: RustDesk's lists take the context
    Future.microtask(() {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final serial = ++_serial;
    final d = _NpfData();
    try {
      switch (widget.cat) {
        case NpfDeskCat.control:
          d.controls = toolbarControls(context, id, ffi);
          d.display = await toolbarDisplayToggle(context, id, ffi);
          if (!mounted) return;
          if (canInput) {
            d.cursor = await toolbarCursor(context, id, ffi);
            d.keyboard = toolbarKeyboardToggles(ffi);
            d.keyboardMode =
                await bind.sessionGetKeyboardMode(sessionId: sid) ??
                    kKeyLegacyMode;
          }
        case NpfDeskCat.picture:
          d.display = await toolbarDisplayToggle(context, id, ffi);
          if (!mounted) return;
          d.viewStyle = await toolbarViewStyle(context, id, ffi);
          d.scrollStyle = await bind.sessionGetScrollStyle(sessionId: sid) ?? '';
          // int on the web bridge, int? on the native one
          final dynamic thickness =
              await bind.sessionGetEdgeScrollEdgeThickness(sessionId: sid);
          d.edgeThickness = thickness is int ? thickness : 0;
          final (picture, codecs) = await _npfReadPicture(sid);
          d.picture = picture;
          d.codecs = codecs;
          if (!mounted) return;
          d.canAdjust = await _adjustor.isWindowCanBeAdjusted(context);
          if (!mounted) return;
          final privacy = PrivacyModeState.find(id);
          if (defaultConn &&
              (pi.features.privacyMode || privacy.isNotEmpty) &&
              (ffiModel.keyboard || privacy.isNotEmpty)) {
            d.privacy = toolbarPrivacyMode(privacy, context, id, ffi);
          }
        case NpfDeskCat.tools:
          d.controls = toolbarControls(context, id, ffi);
          d.display = await toolbarDisplayToggle(context, id, ffi);
          await _readSpeakers(d);
      }
    } catch (e) {
      debugPrint('npf panel ${widget.cat.name}: $e');
    }
    if (!mounted || serial != _serial) return;
    setState(() {
      _d = d;
      _set.clear();
      _virtual = null;
    });
  }

  /// Read again once what was just asked of the session has been done.
  void _later([int ms = 350]) => Future.delayed(Duration(milliseconds: ms), () {
        if (!mounted) return;
        _load();
        _npfTick.value++;
      });

  /// A press that does it and leaves the panel (most open a dialog).
  VoidCallback? _leave(VoidCallback? f) => f == null
      ? null
      : () {
          widget.close();
          f();
        };

  String? _labelOf(Widget w) {
    if (w is Text) return w.data;
    if (w is Row) {
      for (final c in w.children) {
        final s = _labelOf(c);
        if (s != null) return s;
      }
    }
    return null;
  }

  /// One of RustDesk's toggles as a switch; [inverse]: the row says the
  /// opposite ("play the sound" for "mute").
  Widget _toggle(TToggleMenu e,
      {Widget? label, String? note, bool inverse = false, bool indent = false}) {
    final key = e.actionId ?? _labelOf(e.child) ?? e;
    final value = _set[key] ?? e.value;
    return NpfDeskSwitchRow(
        label: label ?? e.child,
        note: note,
        indent: indent,
        value: inverse ? !value : value,
        onChanged: e.onChanged == null
            ? null
            : (v) {
                final to = inverse ? !v : v;
                setState(() => _set[key] = to);
                e.onChanged!(to);
                _later();
              });
  }

  TToggleMenu? _byId(List<TToggleMenu> v, String actionId) =>
      v.firstWhereOrNull((e) => e.actionId == actionId);

  VoidCallback? _control(_NpfData d, String actionId) =>
      d.controls.firstWhereOrNull((e) => e.actionId == actionId)?.onPressed;

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final loading = d == null;
    return NpfDeskPanel(
        width: widget.width,
        maxHeight: widget.maxHeight,
        left: loading
            ? const [SizedBox(height: 120)]
            : switch (widget.cat) {
                NpfDeskCat.control => _controlLeft(d),
                NpfDeskCat.picture => _pictureLeft(d),
                NpfDeskCat.tools => _toolsLeft(d),
              },
        right: loading
            ? const []
            : switch (widget.cat) {
                NpfDeskCat.control => _controlRight(d),
                NpfDeskCat.picture => _pictureRight(d),
                NpfDeskCat.tools => _toolsRight(d),
              });
  }

  // ---- control: this computer

  void _combo(String name,
          {bool ctrl = false, bool alt = false, bool command = false}) =>
      bind.sessionInputKey(
          sessionId: sid,
          name: name,
          down: false,
          press: true,
          alt: alt,
          ctrl: ctrl,
          shift: false,
          command: command);

  // the entry with the pencil beside it: the system's password
  TTextMenu? _password(_NpfData d) =>
      d.controls.firstWhereOrNull((e) => e.trailingIcon != null);

  List<NpfDeskBig> _bigButtons(_NpfData d) {
    VoidCallback? key(VoidCallback f) => canType ? f : null;
    final lock = _control(d, kShortcutActionInsertLock);
    final refresh = NpfDeskBig(NpfDeskIcons.refresh, npfTr('Refresh picture'),
        _control(d, kShortcutActionRefresh));
    final password = NpfDeskBig(NpfDeskIcons.key, npfTr('Type the password'),
        _leave(_password(d)?.onPressed));
    final desktop = NpfDeskBig(NpfDeskIcons.desktop, npfTr('Show desktop'),
        key(() => _combo('VK_D', command: true)));
    final cad = NpfDeskBig(NpfDeskIcons.cad, 'Ctrl+Alt+Del',
        _control(d, kShortcutActionSendCtrlAltDel));
    switch (pi.platform) {
      case kPeerPlatformAndroid:
        final m = ffi.inputModel;
        return [
          NpfDeskBig(NpfDeskIcons.back, translate('Back'), key(m.onMobileBack)),
          NpfDeskBig(NpfDeskIcons.home, translate('Home'), key(m.onMobileHome)),
          NpfDeskBig(
              NpfDeskIcons.recents, translate('Apps'), key(m.onMobileApps)),
          NpfDeskBig(NpfDeskIcons.plus, translate('Volume up'),
              key(m.onMobileVolumeUp)),
          NpfDeskBig(NpfDeskIcons.minus, translate('Volume down'),
              key(m.onMobileVolumeDown)),
          NpfDeskBig(
              NpfDeskIcons.power, translate('Power'), key(m.onMobilePower)),
          refresh,
        ];
      case kPeerPlatformMacOS:
        return [
          NpfDeskBig(NpfDeskIcons.lock, npfTr('Lock screen'), lock),
          NpfDeskBig(NpfDeskIcons.windows, npfTr('Mission Control'),
              key(() => _combo('VK_UP', ctrl: true))),
          NpfDeskBig(NpfDeskIcons.desktop, npfTr('Show desktop'),
              key(() => _combo('VK_F11'))),
          NpfDeskBig(NpfDeskIcons.search, npfTr('Spotlight'),
              key(() => _combo('VK_SPACE', command: true))),
          refresh,
          password,
        ];
      case kPeerPlatformLinux:
        return [
          cad,
          NpfDeskBig(NpfDeskIcons.lock, npfTr('Lock screen'), lock),
          NpfDeskBig(NpfDeskIcons.windows, npfTr('Activities'),
              key(() => _combo('Meta'))),
          desktop,
          refresh,
          password,
        ];
      default:
        return [
          cad,
          NpfDeskBig(NpfDeskIcons.lock, npfTr('Lock'), lock),
          NpfDeskBig(NpfDeskIcons.windows, npfTr('Task view'),
              key(() => _combo('VK_TAB', command: true))),
          desktop,
          refresh,
          password,
        ];
    }
  }

  List<Widget> _controlLeft(_NpfData d) {
    // on the large buttons, a switch below, or in the tools panel
    const elsewhere = {
      kShortcutActionSendCtrlAltDel,
      kShortcutActionInsertLock,
      kShortcutActionRefresh,
      kShortcutActionScreenshot,
      kShortcutActionToggleBlockInput,
    };
    final tools = {
      translate('Transfer file'),
      translate('View camera'),
      '${translate('Terminal')} (beta)',
      translate('TCP tunneling'),
    };
    String icon(TTextMenu e) => switch (e.actionId) {
          kShortcutActionRestartRemote => NpfDeskIcons.power,
          kShortcutActionSendClipboardKeystrokes => NpfDeskIcons.clip,
          kShortcutActionSwitchSides => NpfDeskIcons.swap,
          _ => NpfDeskIcons.shield,
        };
    final password = _password(d);
    final smalls = [
      for (final e in d.controls)
        if (!e.divider &&
            e != password &&
            !elsewhere.contains(e.actionId) &&
            !tools.contains(_labelOf(e.child)))
          NpfDeskSmall(icon(e), e.child, _leave(e.onPressed),
              danger: e.actionId == kShortcutActionRestartRemote),
      if (password != null)
        NpfDeskSmall(
            NpfDeskIcons.edit,
            Text(npfTr('Change the saved password')),
            _leave(() =>
                handleOsPasswordEditIcon(sid, ffi.dialogManager))),
    ];
    final block = _control(d, kShortcutActionToggleBlockInput);
    final lockEnd = _byId(d.display, kShortcutActionToggleLockAfterSessionEnd);
    return [
      NpfDeskLabel(npfTr('This computer')),
      NpfDeskBigButtons(_bigButtons(d)),
      if (smalls.isNotEmpty) NpfDeskSmallButtons(smalls),
      if (block != null)
        Obx(() => NpfDeskSwitchRow(
            label: Text(npfTr('Block their keyboard and mouse')),
            note: npfTr('The person at the computer cannot use it meanwhile'),
            value: BlockInputState.find(id).value,
            onChanged: (_) => block())),
      if (lockEnd != null)
        _toggle(lockEnd,
            label: Text(npfTr('Lock it when the session ends')),
            note: npfTr('The computer goes back to its lock screen')),
    ];
  }

  // ---- control: my mouse and keyboard

  List<Widget> _controlRight(_NpfData d) {
    if (!canInput) return [];
    final canView = versionCmp(pi.version, '1.2.0') >= 0;
    final desktopPeer = [
      kPeerPlatformWindows,
      kPeerPlatformMacOS,
      kPeerPlatformLinux
    ].contains(pi.platform);
    Future<void> readViewOnly(bool wanted) async {
      final viewOnly = await bind.sessionGetToggleOption(
          sessionId: sid, arg: kOptionToggleViewOnly);
      ffiModel.setViewOnly(id, viewOnly ?? wanted);
    }

    return [
      NpfDeskLabel(npfTr('My mouse')),
      NpfDeskSwitchRow(
          label: Text(npfTr('View only')),
          note: npfTr('Only the picture: my mouse and keyboard are not sent'),
          value: _set['view'] ?? ffiModel.viewOnly,
          onChanged: canView
              ? (v) async {
                  setState(() => _set['view'] = v);
                  await bind.sessionToggleOption(
                      sessionId: sid, value: kOptionToggleViewOnly);
                  await readViewOnly(v);
                  final mine = await bind.sessionGetToggleOption(
                      sessionId: sid, arg: kOptionToggleShowMyCursor);
                  ffiModel.setShowMyCursor(mine ?? v);
                  _load();
                }
              : null),
      if (desktopPeer && (_set['view'] ?? ffiModel.viewOnly))
        NpfDeskSwitchRow(
            indent: true,
            label: Text(translate('Show my cursor')),
            value: _set['mine'] ?? ffiModel.showMyCursor,
            onChanged: (v) async {
              setState(() => _set['mine'] = v);
              await bind.sessionToggleOption(
                  sessionId: sid, value: kOptionToggleShowMyCursor);
              final mine = await bind.sessionGetToggleOption(
                      sessionId: sid, arg: kOptionToggleShowMyCursor) ??
                  v;
              ffiModel.setShowMyCursor(mine);
              if (mine && !ffiModel.viewOnly) {
                await bind.sessionToggleOption(
                    sessionId: sid, value: kOptionToggleViewOnly);
                await readViewOnly(v);
              }
              _load();
            }),
      for (final e in d.cursor) _toggle(e),
      for (final e in d.keyboard)
        if (e.actionId != kShortcutActionToggleSwapCtrlCmd) _toggle(e),
      if (isDesktop)
        NpfDeskActionRow(
            label: Text(translate('Trackpad speed')),
            arrow: true,
            onTap: ffiModel.viewOnly
                ? null
                : _leave(() => trackpadSpeedDialog(sid, ffi))),
      ..._keyboard(d),
    ];
  }

  // The desktop has a real keyboard: what is left of the phone's keyboard
  // panel is how the keys are sent.
  List<Widget> _keyboard(_NpfData d) {
    final enabled = !ffiModel.viewOnly;
    String? only;
    if (isInputSourceFlutter && isDesktop) {
      if (bind.sessionIsKeyboardModeSupported(
          sessionId: sid, mode: kKeyMapMode)) {
        only = kKeyMapMode;
      } else if (bind.sessionIsKeyboardModeSupported(
          sessionId: sid, mode: kKeyLegacyMode)) {
        only = kKeyLegacyMode;
      }
    }
    final modes = [
      for (final m in [
        (kKeyMapMode, npfTr('Map')),
        (kKeyTranslateMode, npfTr('Translate')),
        (kKeyLegacyMode, npfTr('Legacy')),
      ])
        if ((only == null || m.$1 == only) &&
            bind.sessionIsKeyboardModeSupported(sessionId: sid, mode: m.$1) &&
            !(pi.isWayland && m.$1 != kKeyMapMode))
          NpfDeskOption(m.$1, Text(m.$2), enabled: enabled)
    ];
    final note = switch (d.keyboardMode) {
      kKeyMapMode => npfTr(
          'Map: a key is the key at the same place. For shortcuts and games.'),
      kKeyTranslateMode => npfTr(
          'Translate: the characters typed are sent. For keyboards of different layouts.'),
      _ => npfTr('Legacy: the old way, when the other two fail.'),
    };
    final local = getLocalPlatformForKBLayoutType(pi.platform);
    var sources = <dynamic>[];
    try {
      final s = bind.mainSupportedInputSource();
      if (s.isNotEmpty) sources = jsonDecode(s) as List<dynamic>;
    } catch (e) {
      debugPrint('npf panel: the input sources: $e');
    }
    final swap = _byId(d.keyboard, kShortcutActionToggleSwapCtrlCmd);
    return [
      if (modes.isNotEmpty) ...[
        NpfDeskLabel(npfTr('How my keyboard is sent')),
        NpfDeskSegment<String>(
            options: modes,
            value: d.keyboardMode,
            onChanged: (v) async {
              await bind.sessionSetKeyboardMode(sessionId: sid, value: v);
              await ffi.inputModel.updateKeyboardMode();
              _load();
            }),
        NpfDeskNote(note),
      ],
      if (sources.length > 1) ...[
        NpfDeskLabel(npfTr('Input source')),
        NpfDeskOptions<String>(
            options: [
              for (final e in sources)
                NpfDeskOption('${(e as List<dynamic>)[0]}',
                    Text(translate('${e[1]}')),
                    enabled: enabled)
            ],
            value: stateGlobal.getInputSource(),
            onChanged: (v) async {
              await stateGlobal.setInputSource(sid, v);
              if (isMacOS) ffi.inputModel.enterOrLeave(false);
              await ffiModel.checkDesktopKeyboardMode();
              await ffi.inputModel.updateKeyboardMode();
              _load();
            }),
      ],
      if (local != '')
        NpfDeskActionRow(
            label: Text(translate('Local keyboard type')),
            value: KBLayoutType.value,
            arrow: true,
            onTap: enabled
                ? _leave(() => showKBLayoutTypeChooser(local, ffi.dialogManager))
                : null),
      if (swap != null) _toggle(swap),
    ];
  }

  // ---- picture: its mode, quality, frame rate and codec

  Future<void> _apply(NpfPicture p) async {
    final old = _d?.picture;
    if (old == null || old == p) return;
    setState(() => _d!.picture = p);
    if (old.quality != p.quality) {
      await bind.sessionSetImageQuality(sessionId: sid, value: p.quality);
    }
    if (old.fps != p.fps) {
      await bind.sessionSetCustomFps(sessionId: sid, fps: p.fps);
    }
    var codec = false;
    if (old.codec != p.codec) {
      await bind.sessionPeerOption(
          sessionId: sid, name: kOptionCodecPreference, value: p.codec);
      codec = true;
    }
    if (bind.sessionGetToggleOptionSync(sessionId: sid, arg: 'i444') !=
        p.i444) {
      await bind.sessionToggleOption(sessionId: sid, value: 'i444');
      codec = true;
    }
    if (codec) bind.sessionChangePreferCodec(sessionId: sid);
    _npfTick.value++;
  }

  List<Widget> _pictureLeft(_NpfData d) {
    final p = d.picture;
    if (p == null) return [];
    final mode = NpfPictureModes.of(p, d.codecs);
    final codecs = NpfPictureModes.codecs(d.codecs);
    const inField = EdgeInsets.fromLTRB(0, 3, 8, 3);
    return [
      NpfDeskLabel(mode == NpfPictureMode.custom
          ? npfTr('Mode · custom')
          : npfTr('Mode')),
      NpfDeskCards<NpfPictureMode>(
          cards: [
            for (final m in const [
              NpfPictureMode.office,
              NpfPictureMode.hd,
              NpfPictureMode.game
            ])
              NpfDeskCard(m, NpfPictureModes.modeName(m),
                  NpfPictureModes.modeLine(m, d.codecs))
          ],
          value: mode,
          onChanged: (m) {
            final to = NpfPictureModes.preset(m, d.codecs);
            if (to != null) _apply(to);
          }),
      NpfDeskNote(NpfPictureModes.modeNote(mode)),
      NpfDeskField(
          npfTr('Quality'),
          NpfDeskSegment<String>(
              padding: inField,
              options: [
                for (final q in const [
                  kRemoteImageQualityLow,
                  kRemoteImageQualityBalanced,
                  kRemoteImageQualityBest,
                  kRemoteImageQualityCustom
                ])
                  NpfDeskOption(q, Text(NpfPictureModes.qualityName(q)))
              ],
              value: p.quality,
              onChanged: (q) async {
                await _apply(p.copyWith(quality: q));
                if (q == kRemoteImageQualityCustom) {
                  widget.close();
                  customImageQualityDialog(sid, id, ffi);
                }
              })),
      NpfDeskField(
          npfTr('Frame rate'),
          NpfDeskSegment<int>(
              padding: inField,
              options: [
                for (final f in {...NpfPictureModes.rates, p.fps}.toList()
                  ..sort())
                  NpfDeskOption(f, Text(npfTr('{n} fps', {'n': f})))
              ],
              value: p.fps,
              onChanged: (f) => _apply(p.copyWith(fps: f)))),
      if (codecs.length > 1)
        NpfDeskField(
            npfTr('Codec'),
            NpfDeskSegment<String>(
                padding: inField,
                options: [
                  for (final c in codecs)
                    NpfDeskOption(c, Text(NpfPictureModes.codecName(c)))
                ],
                value: p.codec,
                onChanged: (c) => _apply(NpfPictureModes.withCodec(p, c)))),
      if (versionCmp(pi.version, '1.2.4') >= 0)
        NpfDeskSwitchRow(
            label: Text(translate('True color (4:4:4)')),
            note: npfTr(
                'Small text and thin lines are clearer. With VP9 or AV1 only'),
            value: p.i444,
            onChanged: (v) => _apply(NpfPictureModes.withI444(p, v))),
    ];
  }

  // ---- picture: its scale, resolution and screens

  List<Widget> _scale(_NpfData d) {
    if (d.viewStyle.isEmpty) return [];
    final style = d.viewStyle.first.groupValue;
    final overflow = style == kRemoteViewStyleOriginal ||
        style == kRemoteViewStyleCustom;
    setScroll(String v) async {
      await bind.sessionSetScrollStyle(sessionId: sid, value: v);
      ffi.canvasModel.updateScrollStyle();
      _load();
    }

    return [
      NpfDeskLabel(npfTr('Scale')),
      NpfDeskSegment<String>(
          options: [
            // "fit the window" first, as the prototype has it
            for (final e in [
              ...d.viewStyle.where((e) => e.value == kRemoteViewStyleAdaptive),
              ...d.viewStyle.where((e) => e.value != kRemoteViewStyleAdaptive)
            ])
              NpfDeskOption(e.value, e.child)
          ],
          value: style,
          onChanged: (v) {
            d.viewStyle.firstWhereOrNull((e) => e.value == v)?.onChanged?.call(v);
            _later();
          }),
      if (style == kRemoteViewStyleCustom)
        _CustomScaleMenuControls(ffi: ffi, onChanged: null),
      if (overflow) ...[
        NpfDeskLabel(npfTr('When the picture is larger than the window')),
        Obx(() => NpfDeskOptions<String>(
                options: [
                  for (final s in [
                    (kRemoteScrollStyleAuto, 'ScrollAuto'),
                    (kRemoteScrollStyleBar, 'Scrollbar'),
                    if (!isWeb) (kRemoteScrollStyleEdge, 'ScrollEdge'),
                  ])
                    NpfDeskOption(s.$1, Text(translate(s.$2)),
                        enabled: ffi.canvasModel.imageOverflow.value)
                ],
                value: d.scrollStyle,
                onChanged: setScroll)),
        if (d.scrollStyle == kRemoteScrollStyleEdge)
          EdgeThicknessControl(
              value: d.edgeThickness.toDouble(),
              colorScheme: Theme.of(context).colorScheme,
              onChanged: (v) async {
                final t = v.round();
                await bind.sessionSetEdgeScrollEdgeThickness(
                    sessionId: sid, value: t);
                ffi.canvasModel.updateEdgeScrollEdgeThickness(t);
                _load();
              }),
      ],
    ];
  }

  /// The virtual screens as one number to step: one more takes the first
  /// free place, one less the last taken.
  Widget? _virtualScreens(RxString privacy) {
    if (!(defaultConn && showVirtualDisplayMenu(ffi))) return null;
    if (!pi.isRustDeskIdd && !pi.isAmyuniIdd) return null;
    // the peer's answer (its displays again) takes a moment
    void plug(int index, bool on, int to) {
      setState(() => _virtual = to);
      bind.sessionToggleVirtualDisplay(sessionId: sid, index: index, on: on);
      _later(1500);
    }

    return Obx(() {
      final locked = privacy.isNotEmpty;
      final VoidCallback? less;
      final VoidCallback? more;
      final int count;
      if (pi.isRustDeskIdd) {
        final plugged = pi.RustDeskVirtualDisplays;
        final free = [
          for (var i = 1; i <= kMaxVirtualDisplayCount; i++)
            if (!plugged.contains(i)) i
        ];
        final last = plugged.fold<int>(0, (a, b) => a > b ? a : b);
        count = plugged.length;
        less = plugged.isEmpty ? null : () => plug(last, false, count - 1);
        more = free.isEmpty ? null : () => plug(free.first, true, count + 1);
      } else {
        count = pi.amyuniVirtualDisplayCount;
        less = count == 0 ? null : () => plug(0, false, count - 1);
        more = count >= 4 ? null : () => plug(0, true, count + 1);
      }
      final asked = _virtual;
      return NpfDeskStepRow(
          label: Text(npfTr('Virtual screens')),
          note: npfTr('Screens the computer does not really have'),
          value: asked ?? count,
          onLess: locked || asked != null ? null : less,
          onMore: locked || asked != null ? null : more);
    });
  }

  List<Widget> _screens(_NpfData d) {
    final privacy = PrivacyModeState.find(id);
    final virtual = _virtualScreens(privacy);
    final canSeparate = !isWeb && pi.isSupportMultiDisplay;
    final separate = _set['separate'] ?? _npfSeparate(ffi);
    return [
      Obx(() {
        _npfTick.value;
        final options = _npfDisplayOptions(id, ffi, long: true);
        final many = options.isNotEmpty;
        if (!many && virtual == null) return const SizedBox.shrink();
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              NpfDeskLabel(npfTr('Screens')),
              if (many)
                NpfDeskSegment<int>(
                    options: options,
                    value: CurrentDisplayState.find(id).value,
                    onChanged: (i) {
                      _npfShowDisplay(id, ffi, i);
                      _later();
                    }),
              if (virtual != null) virtual,
              if (many && canSeparate)
                NpfDeskSwitchRow(
                    label: Text(npfTr('Each screen in its own window')),
                    note: separate
                        ? npfTr(
                            'A number above opens that screen in a window of its own')
                        : npfTr(
                            'For when this side has several monitors too'),
                    value: separate,
                    onChanged: (v) async {
                      setState(() => _set['separate'] = v);
                      await bind.sessionSetDisplaysAsIndividualWindows(
                          sessionId: sid, value: v ? 'Y' : 'N');
                      // "all" is of one window only
                      if (v &&
                          CurrentDisplayState.find(id).value ==
                              kAllDisplayValue) {
                        openMonitorInTheSameTab(0, ffi, pi,
                            updateCursorPos: true);
                      }
                      _later();
                    }),
            ]);
      }),
      for (final e in d.display)
        if (e.actionId == null &&
            _labelOf(e.child) !=
                translate('Show displays as individual windows'))
          _toggle(e),
    ];
  }

  List<Widget> _pictureRight(_NpfData d) {
    final monitor = _byId(d.display, kShortcutActionToggleQualityMonitor);
    return [
      ..._scale(d),
      if (defaultConn)
        Obx(() => CurrentDisplayState.find(id).value == kAllDisplayValue
            ? NpfDeskActionRow(
                label: Text(translate('Resolution')),
                note: npfTr('Not with all the screens shown: choose one first'),
                onTap: null)
            : _ResolutionsMenu(id: id, ffi: ffi, screenAdjustor: _adjustor)),
      if (d.canAdjust)
        NpfDeskActionRow(
            label: Text(translate('Adjust Window')),
            onTap: _leave(() => _adjustor.doAdjustWindow(context))),
      ..._screens(d),
      for (final e in d.privacy)
        _toggle(e,
            note: npfTr(
                'Their screen goes dark: nobody there sees what I do')),
      if (monitor != null) _toggle(monitor),
    ];
  }

  // ---- tools: the person at the computer, a record of the session

  List<Widget> _call() {
    final status = ffi.chatModel.voiceCallStatus.value;
    hangUp() => bind.sessionCloseVoiceCall(sessionId: sid);
    call() => bind.sessionRequestVoiceCall(sessionId: sid);
    switch (status) {
      case VoiceCallStatus.waitingForResponse:
        return [
          NpfDeskStateCard(
              color: NpfDesk.yellow,
              label: Text('${npfTr('Calling')}…'),
              actions: [NpfDeskButton(translate('Cancel'), onTap: hangUp)])
        ];
      case VoiceCallStatus.connected:
        final since = _npfSince(_npfCallSince, ffi.chatModel, true);
        final d = _d;
        return [
          NpfDeskStateCard(
              color: NpfDesk.green,
              label: Row(children: [
                Text(npfTr('In a call')),
                const SizedBox(width: 6),
                if (since != null) NpfDeskElapsed(since),
              ]),
              actions: [
                NpfDeskButton(npfTr('Hang up'), danger: true, onTap: hangUp)
              ]),
          AudioInput(
              isCm: false,
              isVoiceCall: true,
              builder: (devices, current, set) => devices.isEmpty
                  ? const SizedBox.shrink()
                  : NpfDeskSelectRow<String>(
                      icon: NpfDeskIcons.mic,
                      label: Text(npfTr('Microphone')),
                      options: [for (final dev in devices) (dev, dev)],
                      value: current,
                      onChanged: set)),
          if (d != null && d.speakers.isNotEmpty)
            NpfDeskSelectRow<String>(
                icon: NpfDeskIcons.speaker,
                label: Text(npfTr('Speaker')),
                options: [
                  ('', npfTr('As the system')),
                  for (final dev in d.speakers) (dev, dev)
                ],
                value: d.speaker,
                onChanged: (v) async {
                  setState(() => d.speaker = v);
                  await bind.mainSetLocalOption(
                      key: kNpfOptionAudioOutput, value: v);
                }),
        ];
      default:
        return [
          NpfDeskActionRow(
              icon: NpfDeskIcons.phone,
              label: Text(translate('Voice call')),
              note: npfTr('Connects once they accept'),
              trailing: NpfDeskButton(npfTr('Call'), tint: true, onTap: call),
              onTap: call)
        ];
    }
  }

  /// The devices to play the peer's sound on. An ouDesk without the choice
  /// answers nothing: the row is not shown.
  Future<void> _readSpeakers(_NpfData d) async {
    if (isWeb) return;
    try {
      final s = await bind.mainGetCommon(key: kNpfCommonAudioOutputs);
      if (!s.startsWith('[')) return;
      d.speakers = [for (final e in jsonDecode(s) as List<dynamic>) '$e'];
      final now = bind.mainGetLocalOption(key: kNpfOptionAudioOutput);
      d.speaker = d.speakers.contains(now) ? now : '';
    } catch (e) {
      debugPrint('npf panel: the speakers: $e');
    }
  }

  List<Widget> _toolsLeft(_NpfData d) {
    final recording = ffi.recordingModel;
    final canRecord = !isWeb &&
        bind.mainGetLocalOption(key: kOptionHideRecordingButton) != 'Y' &&
        (recording.start || ffiModel.permissions['recording'] != false);
    final shot = d.controls
        .firstWhereOrNull((e) => e.actionId == kShortcutActionScreenshot);
    return [
      NpfDeskLabel(npfTr('The person at the computer')),
      if (!isWeb)
        Obx(() => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: _call())),
      NpfDeskActionRow(
          icon: NpfDeskIcons.chat,
          label: Text(translate('Text chat')),
          onTap: _leave(() => _npfChat(ffi))),
      if (canRecord || shot != null) NpfDeskLabel(npfTr('A record')),
      if (canRecord)
        AnimatedBuilder(
            animation: recording,
            builder: (context, _) => NpfDeskSwitchRow(
                label: Text(npfTr('Record the session')),
                note: npfTr('A video of this session, kept on this computer'),
                value: recording.start,
                onChanged: (_) => recording.toggle())),
      if (shot != null)
        Obx(() {
          final all = CurrentDisplayState.find(id).value == kAllDisplayValue;
          return NpfDeskActionRow(
              label: Text(npfTr('Screenshot')),
              note: all
                  ? npfTr(
                      'Not with all the screens shown: choose one first')
                  : npfTr('Their screen as it is now, to copy or save'),
              trailing: const NpfDeskIcon(NpfDeskIcons.shot,
                  size: 17, color: NpfDesk.dim),
              onTap: all ? null : _leave(shot.onPressed));
        }),
    ];
  }

  // ---- tools: other windows, the sound and the clipboard

  List<Widget> _toolsRight(_NpfData d) {
    final mute = _byId(d.display, kShortcutActionToggleMute);
    final clipboard = _byId(d.display, kShortcutActionToggleDisableClipboard);
    final files = _byId(d.display, kShortcutActionToggleEnableFileCopyPaste);
    void open({bool file = false, bool camera = false, bool terminal = false}) {
      widget.close();
      _npfOpen(context, id, ffi, file: file, camera: camera, terminal: terminal);
    }

    return [
      if (defaultConn && isDesktop) ...[
        const SizedBox(height: 6),
        NpfDeskBigButtons([
          NpfDeskBig(NpfDeskIcons.folder, translate('Transfer file'),
              () => open(file: true)),
          NpfDeskBig(NpfDeskIcons.terminal, translate('Terminal'),
              () => open(terminal: true)),
          NpfDeskBig(NpfDeskIcons.camera, translate('View camera'),
              () => open(camera: true)),
        ]),
      ],
      if (mute != null || clipboard != null || files != null)
        NpfDeskLabel(npfTr('Sound and clipboard')),
      if (mute != null)
        _toggle(mute,
            label: Text(npfTr("Play the computer's sound")), inverse: true),
      if (clipboard != null)
        _toggle(clipboard,
            label: Text(npfTr('Sync the clipboard')),
            note: npfTr('Text copied on one side pastes on the other'),
            inverse: true),
      if (files != null)
        _toggle(files,
            note: npfTr('Copy files on one side, paste them on the other')),
    ];
  }
}
