// Test helpers: a real CJK font for the goldens, and a frame for the pages.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const kNpfTestFont = 'NpfTest';

/// Loads a font with Chinese glyphs as [kNpfTestFont]: the regular and bold
/// files from $NPF_TEST_FONTS (or Windows' DengXian, or Noto Sans CJK).
/// Returns false when none is found (the goldens then show boxes).
Future<bool> loadNpfTestFont() async {
  final env = Platform.environment['NPF_TEST_FONTS'];
  final candidates = <List<String>>[
    if (env != null) [for (final f in env.split(':')) f],
    ['/mnt/c/Windows/Fonts/Deng.ttf', '/mnt/c/Windows/Fonts/Dengb.ttf'],
    ['C:/Windows/Fonts/Deng.ttf', 'C:/Windows/Fonts/Dengb.ttf'],
    [
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc'
    ],
  ];
  for (final files in candidates) {
    final found = files.where((f) => File(f).existsSync()).toList();
    if (found.isEmpty) continue;
    final loader = FontLoader(kNpfTestFont);
    for (final f in found) {
      final bytes = File(f).readAsBytesSync();
      loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    }
    await loader.load();
    return true;
  }
  return false;
}

ThemeData npfTestTheme({Brightness brightness = Brightness.light}) => ThemeData(
      brightness: brightness,
      fontFamily: kNpfTestFont,
      useMaterial3: true,
      colorSchemeSeed: const Color(0xFF2563EB),
    );

/// Shows [child] alone in a window of [size] (logical pixels, ratio 1).
Future<void> pumpNpf(WidgetTester tester, Widget child,
    {required Size size, Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: npfTestTheme(brightness: brightness),
    home: Scaffold(body: child),
  ));
  await settle(tester);
}

/// Lets the stub's futures complete and the frames settle (the pages tick
/// every second, so no pumpAndSettle).
Future<void> settle(WidgetTester tester, {bool ink = false}) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  // let ink splashes and dialog transitions finish (under a second, so the
  // pages' one-second tick does not fire)
  if (ink) await tester.pump(const Duration(milliseconds: 800));
}

/// Keeps the clipboard calls of the pages quiet.
void mockClipboard() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
}
