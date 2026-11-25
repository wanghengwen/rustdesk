// ouDesk inside ouLink's app (npf's) on Android and iOS (add-to-app): RustDesk's
// controlling pages, one Flutter engine per session (its own gFFI and
// picture), started by the host with the arguments [action, id] (action:
// desktop|files|terminal) and opening that session; over "npf.oudesk":
//   host -> Dart  close (the session ends: its card closed in the app)
//   Dart -> host  done (the session page is gone: the engine ends)
//   Dart -> host  leave {name} (back on the session page: it stays, out of
//                 sight; name: the peer's host name)
// Out of sight (left, the app in the background) a remote desktop gets
// 1 frame a second (sessionNpfBackground), its fps again when back.
// Back is Android's back key; on iOS a swipe from the left edge (as
// RustDesk's iOS terminal page has it, the terminal keeping its own).

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/overlay.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/terminal_connection_manager.dart';
import 'package:flutter_hbb/desktop/widgets/refresh_wrapper.dart';
import 'package:flutter_hbb/main.dart' show initEnv;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/npf/npf_session.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

const _channel = MethodChannel('npf.oudesk');
const _actions = {'desktop', 'files', 'terminal'};

/// This engine's session.
String _action = '';
String _id = '';

/// Its page is above the idle page (until `done`).
bool _shown = false;

/// The remote desktop gets 1 frame a second (out of sight).
bool _background = false;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  npfIosDirs = isIOS;
  await initEnv(kAppTypeMain);
  draggablePositions.load();
  // a tap clicks where it touches (RustDesk's mouse mode, a click at the
  // cursor, stays one tap away in the toolbar, and is kept once chosen)
  if (bind.mainGetLocalOption(key: kOptionTouchMode).isEmpty) {
    await bind.mainSetLocalOption(key: kOptionTouchMode, value: 'Y');
  }
  npfLeaveSession = () =>
      _tell('leave', {'name': gFFI.ffiModel.pi.hostname});
  _channel.setMethodCallHandler(_onHostCall);
  runApp(const _OuDeskApp());
  if (args.length == 2 && _actions.contains(args[0]) && args[1].trim().isNotEmpty) {
    _action = args[0];
    _id = args[1].trim();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  } else {
    debugPrint('npf.oudesk: no session in $args');
    _tell('done');
  }
}

void _tell(String method, [Map<String, String>? args]) {
  _channel.invokeMethod(method, args).catchError((e) {
    debugPrint('npf.oudesk $method: $e');
  });
}

Future<Object?> _onHostCall(MethodCall call) async {
  if (call.method != 'close') throw MissingPluginException();
  _close();
  return null;
}

Future<void> _open() async {
  _shown = true;
  try {
    await connect(globalKey.currentContext!, _id,
        isFileTransfer: _action == 'files', isTerminal: _action == 'terminal');
  } catch (e) {
    debugPrint('npf.oudesk: open $_action $_id: $e');
    _shown = false;
    _tell('done');
  }
}

/// The session ends, its page out of sight (no frames there): closed at
/// once, as the page's dispose would; the page goes when frames come.
void _close() {
  if (!_shown) return _tell('done');
  final ffi = _action == 'terminal'
      ? TerminalConnectionManager.getExistingConnection(_id)
      : gFFI;
  if (ffi != null) unawaited(bind.sessionClose(sessionId: ffi.sessionId));
  globalKey.currentState?.popUntil((r) => r.isFirst);   // `done` follows
}

/// The remote desktop out of sight (or back): 1 frame a second.
void _setBackground(bool b) {
  if (b == _background || !_shown || _action != 'desktop') return;
  _background = b;
  unawaited(bind.sessionNpfBackground(sessionId: gFFI.sessionId, background: b));
}

/// Sends `done` when the last session page is popped (back, disconnect,
/// closed by the peer: RustDesk pops to the root page).
class _SessionObserver extends NavigatorObserver {
  @override
  void didPop(Route route, Route? previousRoute) => _check();

  @override
  void didRemove(Route route, Route? previousRoute) => _check();

  void _check() => scheduleMicrotask(() {
        if (!_shown) return;
        if (globalKey.currentState?.canPop() ?? true) return;
        _shown = false;
        _tell('done');
      });
}

class _OuDeskApp extends StatefulWidget {
  const _OuDeskApp();

  @override
  State<_OuDeskApp> createState() => _OuDeskAppState();
}

class _OuDeskAppState extends State<_OuDeskApp> with WidgetsBindingObserver {
  final _observers = [_SessionObserver()];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateOrientation());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() => _updateOrientation();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setBackground(false);
    } else if (state != AppLifecycleState.inactive) {
      _setBackground(true);              // hidden, paused, detached (left)
    }
  }

  @override
  void didChangePlatformBrightness() {
    if (MyTheme.getThemeModePreference() != ThemeMode.system) return;
    Get.changeThemeMode(MyTheme.currentThemeMode());
  }

  // as flutter_hbb's App: from the view's size, not MediaQuery
  void _updateOrientation() {
    if (!mounted) return;
    stateGlobal.isPortrait.value = View.of(context).physicalSize.aspectRatio <= 1;
  }

  @override
  Widget build(BuildContext context) => RefreshWrapper(
      builder: (context) => MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: gFFI.ffiModel),
              ChangeNotifierProvider.value(value: gFFI.imageModel),
              ChangeNotifierProvider.value(value: gFFI.cursorModel),
              ChangeNotifierProvider.value(value: gFFI.canvasModel),
              ChangeNotifierProvider.value(value: gFFI.peerTabModel),
            ],
            child: GetMaterialApp(
              navigatorKey: globalKey,
              debugShowCheckedModeBanner: false,
              title: bind.mainGetAppNameSync(),
              theme: MyTheme.lightTheme,
              darkTheme: MyTheme.darkTheme,
              themeMode: MyTheme.currentThemeMode(),
              home: const _Idle(),
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              supportedLocales: supportedLocales,
              navigatorObservers: _observers,
              // no AccessibilityListener (flutter_hbb's App): it doubles a
              // touch of size 1, for RustDesk's own controlled side
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.0)),
                child: isIOS && _action != 'terminal'
                    ? _EdgeBack(child: child ?? const SizedBox.shrink())
                    : child ?? const SizedBox.shrink(),
              ),
            ),
          ));
}

/// Shown while no session page is open.
class _Idle extends StatelessWidget {
  const _Idle();

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.expand());
}

/// iOS: a swipe from the left edge is back (the page's WillPopScope: the
/// session left, a folder up). The edge watches only: a tap there, or a
/// drag that is no swipe, goes on to the page.
class _EdgeBack extends StatefulWidget {
  final Widget child;
  const _EdgeBack({required this.child});

  @override
  State<_EdgeBack> createState() => _EdgeBackState();
}

class _EdgeBackState extends State<_EdgeBack> {
  double _from = -1;
  double _to = -1;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        // as RustDesk's iOS terminal page: the edge ~10% of the width, the
        // swipe ~25% of it
        final edge = (c.maxWidth * 0.1).clamp(20.0, 80.0);
        final swipe = (c.maxWidth * 0.25).clamp(80.0, 300.0);
        return RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: {
            HorizontalDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                        HorizontalDragGestureRecognizer>(
                    () => HorizontalDragGestureRecognizer(
                        supportedDevices: kTouchBasedDeviceKinds),
                    (r) => r
                      ..onDown = (d) {
                        _from = _to = d.localPosition.dx;
                      }
                      ..onUpdate = (d) {
                        _to = d.localPosition.dx;
                      }
                      ..onEnd = (_) {
                        if (_from >= 0 && _from < edge && _to - _from > swipe) {
                          globalKey.currentState?.maybePop();
                        }
                        _from = _to = -1;
                      }
                      ..onCancel = () {
                        _from = _to = -1;
                      }),
          },
          child: widget.child,
        );
      });
}
