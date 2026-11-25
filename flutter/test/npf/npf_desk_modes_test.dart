import 'package:flutter_hbb/npf/npf_desk_modes.dart';
import 'package:flutter_hbb/npf/npf_desk_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const none = <String>{};
  const hw = {'h264', 'h265'};

  test('a mode is its preset, anything else is custom', () {
    const office = NpfPicture(quality: 'balanced', fps: 30, codec: 'auto');
    expect(NpfPictureModes.preset(NpfPictureMode.office, hw), office);
    expect(NpfPictureModes.of(office, hw), NpfPictureMode.office);
    expect(NpfPictureModes.of(office.copyWith(fps: 60), hw),
        NpfPictureMode.custom);
    expect(NpfPictureModes.of(office.copyWith(i444: true), hw),
        NpfPictureMode.custom);
    expect(NpfPictureModes.preset(NpfPictureMode.custom, hw), isNull);
  });

  test('the sharp and the fast modes take the hardware codecs both sides have',
      () {
    expect(NpfPictureModes.preset(NpfPictureMode.hd, hw)!.codec, 'h265');
    expect(NpfPictureModes.preset(NpfPictureMode.game, hw)!.codec, 'h264');
    expect(NpfPictureModes.preset(NpfPictureMode.hd, none)!.codec, 'auto');
    expect(NpfPictureModes.preset(NpfPictureMode.game, none)!.codec, 'auto');
    expect(
        NpfPictureModes.of(
            const NpfPicture(quality: 'low', fps: 60, codec: 'auto'), none),
        NpfPictureMode.game);
  });

  test('4:4:4 goes with VP9 and AV1 only', () {
    const p = NpfPicture(quality: 'best', fps: 60, codec: 'h265');
    final on = NpfPictureModes.withI444(p, true);
    expect(on.codec, 'vp9');
    expect(on.i444, isTrue);
    expect(
        NpfPictureModes.withI444(p.copyWith(codec: 'av1'), true).codec, 'av1');
    final back = NpfPictureModes.withCodec(on, 'h264');
    expect(back.i444, isFalse);
    expect(NpfPictureModes.withCodec(on, 'av1').i444, isTrue);
  });

  test('the codecs to choose from are those both sides have', () {
    final has = NpfPictureModes.parseCodecs(
        '{"vp8":false,"av1":true,"h264":true,"h265":false}');
    expect(has, {'av1', 'h264'});
    expect(NpfPictureModes.codecs(has), ['auto', 'h264', 'vp9', 'av1']);
    expect(NpfPictureModes.parseCodecs('nonsense'), isEmpty);
    expect(NpfPictureModes.codecs(const {}), ['auto', 'vp9']);
    // H.265 before H.264
    expect(NpfPictureModes.codecs(hw), ['auto', 'h265', 'h264', 'vp9']);
  });

  test('90 frames can be chosen', () {
    expect(NpfPictureModes.rates, [30, 60, 90]);
  });

  test('the clocks of the recording and the call', () {
    expect(npfDeskElapsed(const Duration(seconds: 312)), '05:12');
    expect(npfDeskElapsed(const Duration(seconds: 3912)), '1:05:12');
    expect(npfDeskElapsed(const Duration(seconds: -3)), '00:00');
  });
}
