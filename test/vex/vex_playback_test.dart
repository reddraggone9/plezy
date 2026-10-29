import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/vex/vex_playback.dart';

// Fire HD 10 (2023): MT8186A, H.264/HEVC Main to 1080p60, no AV1/VP9, SDR 1920x1200 panel.
const _fire = VexDeviceLimits(
  codecs: {
    'h264': VexCodecLimits(maxWidth: 4096, maxHeight: 2304, fhd60: true, fhd30: true),
    'hevc': VexCodecLimits(maxWidth: 4096, maxHeight: 2304, fhd60: true, fhd30: true),
  },
  displayLong: 1920,
  displayShort: 1200,
);

Map<String, String> _conditions(Map<String, Object?> profile) => {
  for (final c in profile['Conditions']! as List) (c as Map)['Property'] as String: c['Value'] as String,
};

void main() {
  test('parses the native probe map', () {
    final limits = VexDeviceLimits.fromMap({
      'codecs': {
        'h264': {'maxWidth': 4096, 'maxHeight': 2304, 'fhd60': true, 'tenBit': false},
        'av1': {'maxWidth': 0, 'maxHeight': 0},
      },
      'display': {'longSide': 1920, 'shortSide': 1200, 'hdr': <Object?>[]},
    })!;
    expect(limits.codecs.keys, ['h264']);
    expect(limits.codecs['h264']!.fhd60, isTrue);
    expect(limits.hasDisplay, isTrue);
    expect(limits.displayHdr, isEmpty);
  });

  test('Fire HD 10 profiles cap hardware codecs to the display, 60 fps, 8-bit SDR', () {
    final profiles = buildVexJellyfinCodecProfiles(_fire);
    final h264 = profiles.firstWhere((p) => p['Codec'] == 'h264');
    expect(_conditions(h264), {
      'Width': '1920',
      'Height': '1200',
      'VideoFramerate': '61',
      'VideoBitDepth': '8',
      'VideoRangeType': 'SDR',
    });
    expect(profiles.any((p) => p['Codec'] == 'hevc,h265'), isTrue);
    final global = profiles.last;
    expect(global.containsKey('Codec'), isFalse);
    expect(_conditions(global), {'Width': '1920', 'Height': '1200'});
  });

  test('a 4K30-only HDR TV decoder gets 30 fps above 1080p and no range limit', () {
    const tv = VexDeviceLimits(
      codecs: {'hevc': VexCodecLimits(maxWidth: 3840, maxHeight: 2160, uhd30: true, fhd60: true, tenBit: true)},
      displayLong: 3840,
      displayShort: 2160,
      displayHdr: ['HDR10'],
    );
    final hevc = _conditions(buildVexJellyfinCodecProfiles(tv).first);
    expect(hevc['VideoFramerate'], '31');
    expect(hevc['VideoBitDepth'], '10');
    expect(hevc.containsKey('VideoRangeType'), isFalse);
  });

  test('heavy codecs without a hardware decoder leave the direct-play list', () {
    expect(vexAllowsDirectPlayCodec('vp9', _fire), isFalse);
    expect(vexAllowsDirectPlayCodec('av1', _fire), isFalse);
    expect(vexAllowsDirectPlayCodec('h265', _fire), isTrue);
    expect(vexAllowsDirectPlayCodec('mpeg2video', _fire), isTrue);
    VexDeviceLimits.debugCurrent = null;
    expect(vexAllowsDirectPlayCodec('vp9'), isTrue);
  });

  test('forced transcode is one retry per item', () {
    VexForcedTranscode.debugReset();
    expect(VexForcedTranscode.isForced('a'), isFalse);
    expect(VexForcedTranscode.mark('a'), isTrue);
    expect(VexForcedTranscode.mark('a'), isFalse);
    expect(VexForcedTranscode.isForced('a'), isTrue);
  });
}
