// Builds MP4 files shaped like Jellyfin's progressive transcode (empty_moov,
// one fragment per keyframe) for the Vex transcode checks.
import 'dart:typed_data';

Uint8List mp4Box(String type, List<int> body) {
  final out = BytesBuilder()
    ..add(u32(8 + body.length))
    ..add(type.codeUnits)
    ..add(body);
  return out.toBytes();
}

List<int> u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();
List<int> u64(int v) => (ByteData(8)..setUint64(0, v)).buffer.asUint8List();
List<int> fullBox(int version, int flags) => [version, (flags >> 16) & 0xff, (flags >> 8) & 0xff, flags & 0xff];

Uint8List _trak(int id, int timescale) => mp4Box('trak', [
  ...mp4Box('tkhd', [...fullBox(0, 3), ...u32(0), ...u32(0), ...u32(id), ...List.filled(68, 0)]),
  ...mp4Box('mdia', [
    ...mp4Box('mdhd', [...fullBox(0, 0), ...u32(0), ...u32(0), ...u32(timescale), ...u32(0), ...List.filled(4, 0)]),
  ]),
]);

/// An empty_moov file like Jellyfin's progressive transcode: video at 90 kHz,
/// audio at 48 kHz, one 2 s fragment per track and step.
Uint8List fragmentedMp4({required int fragments, bool cutLastMdat = false}) {
  final out = BytesBuilder()
    ..add(mp4Box('ftyp', 'isom'.codeUnits + u32(512) + 'isomiso6mp41'.codeUnits))
    ..add(
      mp4Box('moov', [
        ...mp4Box('mvhd', [...fullBox(0, 0), ...u32(0), ...u32(0), ...u32(1000), ...u32(0), ...List.filled(80, 0)]),
        ..._trak(1, 90000),
        ..._trak(2, 48000),
        ...mp4Box('mvex', [
          ...mp4Box('trex', [...fullBox(0, 0), ...u32(1), ...u32(1), ...u32(3000), ...u32(0), ...u32(0)]),
          ...mp4Box('trex', [...fullBox(0, 0), ...u32(2), ...u32(1), ...u32(1024), ...u32(0), ...u32(0)]),
        ]),
      ]),
    );
  for (var i = 0; i < fragments; i++) {
    // video: 60 samples of 3000 (trex default, no per-sample durations)
    final videoTraf = mp4Box('traf', [
      ...mp4Box('tfhd', [...fullBox(0, 0x020000), ...u32(1)]),
      ...mp4Box('tfdt', [...fullBox(1, 0), ...u64(i * 180000)]),
      ...mp4Box('trun', [...fullBox(0, 0x001), ...u32(60), ...u32(0)]),
    ]);
    // audio: 2 s as explicit per-sample durations (93 * 1024 + 1 * 1152 + rest)
    final durations = [...List.filled(93, 1024), 96000 - 93 * 1024];
    final audioTraf = mp4Box('traf', [
      ...mp4Box('tfhd', [...fullBox(0, 0x020000), ...u32(2)]),
      ...mp4Box('tfdt', [...fullBox(1, 0), ...u64(i * 96000)]),
      ...mp4Box('trun', [
        ...fullBox(0, 0x101),
        ...u32(durations.length),
        ...u32(0),
        for (final d in durations) ...u32(d),
      ]),
    ]);
    out
      ..add(
        mp4Box('moof', [
          ...mp4Box('mfhd', [...fullBox(0, 0), ...u32(i + 1)]),
          ...videoTraf,
          ...audioTraf,
        ]),
      )
      ..add(mp4Box('mdat', List.filled(64, 0)));
  }
  if (cutLastMdat) {
    final bytes = out.toBytes();
    return Uint8List.sublistView(bytes, 0, bytes.length - 10);
  }
  return out.toBytes();
}
