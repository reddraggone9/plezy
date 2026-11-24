import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/vex/transcode_check.dart';

import 'fmp4_fixture.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('vex_transcode_check'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Duration?> durationOf(Uint8List bytes) async {
    final file = File('${dir.path}/f.mp4')..writeAsBytesSync(bytes);
    return VexTranscodeCheck.fragmentedMp4Duration(file);
  }

  test('reads the end of the last fragment of a fragmented MP4', () async {
    expect(await durationOf(fragmentedMp4(fragments: 30)), const Duration(seconds: 60));
  });

  test('ignores a fragment whose data was cut off', () async {
    // The last moof is complete but its mdat is cut: the walk stops at the
    // incomplete box, so the last fragment still counts (its header arrived).
    expect(await durationOf(fragmentedMp4(fragments: 30, cutLastMdat: true)), const Duration(seconds: 60));
  });

  test('falls back to the movie header for a non-fragmented file', () async {
    final bytes = mp4Box('moov', [
      ...mp4Box('mvhd', [...fullBox(0, 0), ...u32(0), ...u32(0), ...u32(600), ...u32(600 * 95), ...List.filled(80, 0)]),
    ]);
    expect(await durationOf(bytes), const Duration(seconds: 95));
  });

  test('not an MP4: no duration', () async {
    expect(await durationOf(Uint8List.fromList('not a video at all'.codeUnits)), isNull);
  });

  test('a transcode short by more than 15 s or 1% ended early', () {
    expect(VexTranscodeCheck.isShort(84 * 60000 - 1000, 84 * 60000), isFalse);
    expect(VexTranscodeCheck.isShort(84 * 60000 - 45000, 84 * 60000), isFalse); // within 1% (50.4 s)
    expect(VexTranscodeCheck.isShort(61 * 60000 + 35000, 84 * 60000), isTrue); // e7 on 11-24
    expect(VexTranscodeCheck.isShort(60000 - 14000, 60000), isFalse);
    expect(VexTranscodeCheck.isShort(60000 - 16000, 60000), isTrue);
  });
}
