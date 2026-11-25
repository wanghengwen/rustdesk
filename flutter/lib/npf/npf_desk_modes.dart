// The picture's modes (npf's docs/design/oudesk-ui.md 2.3): a mode stands for
// an image quality, a frame rate and a codec, in RustDesk's names; a picture
// that is no mode's is "custom". As the phone pages' DeskMode (Kotlin, Swift).

import 'dart:convert';

import 'npf_lang.dart';

/// The picture as asked of the peer: RustDesk's image quality ("best",
/// "balanced", "low", "custom"), custom-fps, codec-preference ("auto",
/// "h264", ...), i444.
class NpfPicture {
  final String quality;
  final int fps;
  final String codec;
  final bool i444;
  const NpfPicture(
      {required this.quality,
      required this.fps,
      required this.codec,
      this.i444 = false});

  NpfPicture copyWith({String? quality, int? fps, String? codec, bool? i444}) =>
      NpfPicture(
          quality: quality ?? this.quality,
          fps: fps ?? this.fps,
          codec: codec ?? this.codec,
          i444: i444 ?? this.i444);

  @override
  bool operator ==(Object other) =>
      other is NpfPicture &&
      other.quality == quality &&
      other.fps == fps &&
      other.codec == codec &&
      other.i444 == i444;

  @override
  int get hashCode => Object.hash(quality, fps, codec, i444);

  @override
  String toString() => '$quality $fps $codec${i444 ? ' 444' : ''}';
}

enum NpfPictureMode { office, hd, game, custom }

class NpfPictureModes {
  /// the codecs 4:4:4 goes with
  static const _full = {'vp9', 'av1'};

  /// A mode's picture; [has]: the codecs both sides have besides VP9
  /// (alternative_codecs).
  static NpfPicture? preset(NpfPictureMode m, Set<String> has) => switch (m) {
        NpfPictureMode.office =>
          const NpfPicture(quality: 'balanced', fps: 30, codec: 'auto'),
        // the sharpest picture: H.265 where both sides have it in hardware
        NpfPictureMode.hd => NpfPicture(
            quality: 'best',
            fps: 60,
            codec: has.contains('h265') ? 'h265' : 'auto'),
        // the least delay: H.264 in hardware
        NpfPictureMode.game => NpfPicture(
            quality: 'low',
            fps: 60,
            codec: has.contains('h264') ? 'h264' : 'auto'),
        NpfPictureMode.custom => null,
      };

  /// The mode a picture is.
  static NpfPictureMode of(NpfPicture p, Set<String> has) =>
      NpfPictureMode.values.firstWhere((m) => preset(m, has) == p,
          orElse: () => NpfPictureMode.custom);

  /// 4:4:4 on takes a codec that has it (VP9 unless it is AV1 already).
  static NpfPicture withI444(NpfPicture p, bool on) => p.copyWith(
      i444: on, codec: on && !_full.contains(p.codec) ? 'vp9' : p.codec);

  /// Another codec: 4:4:4 stays only with those that have it.
  static NpfPicture withCodec(NpfPicture p, String codec) =>
      p.copyWith(codec: codec, i444: p.i444 && _full.contains(codec));

  /// The frame rates to choose from (RustDesk takes up to 120).
  static const rates = [30, 60, 90];

  /// The codecs to choose from, in the panel's order.
  static List<String> codecs(Set<String> has) => [
        for (final c in const ['auto', 'h265', 'h264', 'vp8', 'vp9', 'av1'])
          if (c == 'auto' || c == 'vp9' || has.contains(c)) c
      ];

  /// alternative_codecs' answer ({"vp8":false,"av1":true,...}): those that
  /// are true.
  static Set<String> parseCodecs(String json) {
    try {
      final m = jsonDecode(json);
      if (m is Map) {
        return {
          for (final e in m.entries)
            if (e.value == true) '${e.key}'
        };
      }
    } catch (_) {}
    return {};
  }

  static String codecName(String c) => switch (c) {
        'auto' => npfTr('Auto'),
        'h264' => 'H.264',
        'h265' => 'H.265',
        _ => c.toUpperCase(),
      };

  static String qualityName(String q) => switch (q) {
        'best' => npfTr('Sharp'),
        'low' => npfTr('Smooth'),
        'custom' => npfTr('Custom'),
        _ => npfTr('Balanced'),
      };

  static String modeName(NpfPictureMode m) => switch (m) {
        NpfPictureMode.office => npfTr('Office'),
        NpfPictureMode.hd => npfTr('HD'),
        NpfPictureMode.game => npfTr('Game'),
        NpfPictureMode.custom => npfTr('Custom'),
      };

  /// What a mode is for, under the cards.
  static String modeNote(NpfPictureMode m) => switch (m) {
        NpfPictureMode.office =>
          npfTr('Documents and help: a balanced picture at 30 frames, the least traffic.'),
        NpfPictureMode.hd =>
          npfTr('Pictures, design and video: the sharpest picture at 60 frames.'),
        NpfPictureMode.game =>
          npfTr('The least delay: a smooth picture at 60 frames.'),
        NpfPictureMode.custom =>
          npfTr('Your own quality, frame rate and codec.'),
      };

  /// What a mode sets, on its card: "均衡 · 30 帧".
  static String modeLine(NpfPictureMode m, Set<String> has) {
    final p = preset(m, has);
    return p == null
        ? ''
        : '${qualityName(p.quality)} · ${npfTr('{n} fps', {'n': p.fps})}';
  }

  /// "均衡 · 30 帧 · 自动"
  static String summary(NpfPicture p) =>
      '${qualityName(p.quality)} · ${npfTr('{n} fps', {'n': p.fps})} · ${codecName(p.codec)}';
}
