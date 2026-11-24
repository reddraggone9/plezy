// Vex fork: a device-compatible download is a live server transcode with no
// Content-Length, so the downloader reports it complete whenever the stream
// ends cleanly, including when the server stopped the transcode early. Check
// the file's own duration before the download is recorded as complete.
import 'dart:io';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';

import '../media/media_item.dart';
import '../utils/app_logger.dart';

abstract final class VexTranscodeCheck {
  /// True if [task] is a device-compatible transcode (the only downloads that
  /// cannot pause) whose file at [path] plays for clearly less than
  /// [metadata]'s runtime. Unknown runtime or an unreadable file is not
  /// evidence of truncation.
  static Future<bool> endedEarly(Task task, String path, Future<MediaItem?> Function() metadata) async {
    if (task.allowPause) return false;
    final expectedMs = (await metadata())?.durationMs;
    if (expectedMs == null || expectedMs <= 0) return false;
    final actual = await fragmentedMp4Duration(File(path));
    if (actual == null) return false;
    final short = isShort(actual.inMilliseconds, expectedMs);
    if (short) {
      appLogger.w(
        'Transcoded download ${task.taskId} ends at ${actual.inSeconds}s of ${expectedMs ~/ 1000}s; '
        'the server stopped the transcode early',
      );
    }
    return short;
  }

  /// A transcode legitimately ends a frame or an audio packet early; anything
  /// beyond 15 s or 1% of the runtime is a cut transcode.
  static bool isShort(int actualMs, int expectedMs) {
    final tolerance = expectedMs ~/ 100 > 15000 ? expectedMs ~/ 100 : 15000;
    return actualMs < expectedMs - tolerance;
  }

  /// Duration of an MP4 file: the end of its last complete fragment for a
  /// fragmented file (Jellyfin's progressive transcode), else the movie header
  /// duration. Null if the file is not a readable MP4.
  static Future<Duration?> fragmentedMp4Duration(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final length = await raf.length();
      final timescales = <int, int>{}; // track id -> media timescale
      final defaultDurations = <int, int>{}; // track id -> trex default sample duration
      final ends = <int, int>{}; // track id -> end of the last fragment, in track units
      int? movieDuration, movieTimescale;
      var offset = 0;
      while (offset + 8 <= length) {
        await raf.setPosition(offset);
        final header = await raf.read(16);
        if (header.length < 8) break;
        final view = ByteData.sublistView(header);
        var size = view.getUint32(0);
        final type = String.fromCharCodes(header.sublist(4, 8));
        var headerSize = 8;
        if (size == 1) {
          if (header.length < 16) break;
          size = view.getUint64(8);
          headerSize = 16;
        } else if (size == 0) {
          size = length - offset;
        }
        if (size < headerSize || offset + size > length) break; // cut mid-box
        if (type == 'moov' || type == 'moof') {
          await raf.setPosition(offset + headerSize);
          final body = ByteData.sublistView(await raf.read(size - headerSize));
          if (type == 'moov') {
            final mvhd = _parseMoov(body, timescales, defaultDurations);
            movieTimescale = mvhd?.$1;
            movieDuration = mvhd?.$2;
          } else {
            _parseMoof(body, defaultDurations, ends);
          }
        }
        offset += size;
      }
      Duration? longest;
      ends.forEach((track, end) {
        final scale = timescales[track];
        if (scale == null || scale <= 0) return;
        final d = Duration(microseconds: end * 1000000 ~/ scale);
        if (longest == null || d > longest!) longest = d;
      });
      if (longest != null) return longest;
      if (movieDuration != null && movieTimescale != null && movieTimescale > 0 && movieDuration > 0) {
        return Duration(microseconds: movieDuration * 1000000 ~/ movieTimescale);
      }
      return null;
    } catch (e) {
      appLogger.d('Could not read MP4 duration of ${file.path}: $e');
      return null;
    } finally {
      await raf?.close();
    }
  }

  /// Children of a box body as (type, start, end) offsets within [body].
  static Iterable<(String, int, int)> _children(ByteData body, [int start = 0, int? end]) sync* {
    final limit = end ?? body.lengthInBytes;
    var at = start;
    while (at + 8 <= limit) {
      var size = body.getUint32(at);
      var headerSize = 8;
      if (size == 1) {
        if (at + 16 > limit) return;
        size = body.getUint64(at + 8);
        headerSize = 16;
      } else if (size == 0) {
        size = limit - at;
      }
      if (size < headerSize || at + size > limit) return;
      final type = String.fromCharCodes([
        body.getUint8(at + 4),
        body.getUint8(at + 5),
        body.getUint8(at + 6),
        body.getUint8(at + 7),
      ]);
      yield (type, at + headerSize, at + size);
      at += size;
    }
  }

  /// Track timescales and default sample durations; returns the movie
  /// header's (timescale, duration).
  static (int, int)? _parseMoov(ByteData moov, Map<int, int> timescales, Map<int, int> defaultDurations) {
    (int, int)? movie;
    for (final (type, start, end) in _children(moov)) {
      if (type == 'mvhd') {
        final version = moov.getUint8(start);
        movie = version == 1
            ? (moov.getUint32(start + 20), moov.getUint64(start + 24))
            : (moov.getUint32(start + 12), moov.getUint32(start + 16));
      } else if (type == 'trak') {
        int? trackId, timescale;
        for (final (t, s, e) in _children(moov, start, end)) {
          if (t == 'tkhd') {
            trackId = moov.getUint32(s + (moov.getUint8(s) == 1 ? 20 : 12));
          } else if (t == 'mdia') {
            for (final (m, ms, _) in _children(moov, s, e)) {
              if (m == 'mdhd') timescale = moov.getUint32(ms + (moov.getUint8(ms) == 1 ? 20 : 12));
            }
          }
        }
        if (trackId != null && timescale != null) timescales[trackId] = timescale;
      } else if (type == 'mvex') {
        for (final (t, s, _) in _children(moov, start, end)) {
          if (t == 'trex') defaultDurations[moov.getUint32(s + 4)] = moov.getUint32(s + 12);
        }
      }
    }
    return movie;
  }

  /// Record where each track's samples in this fragment end.
  static void _parseMoof(ByteData moof, Map<int, int> defaultDurations, Map<int, int> ends) {
    for (final (type, start, end) in _children(moof)) {
      if (type != 'traf') continue;
      int? trackId, defaultDuration, baseTime;
      var total = 0;
      for (final (t, s, _) in _children(moof, start, end)) {
        if (t == 'tfhd') {
          final flags = moof.getUint32(s) & 0xffffff;
          trackId = moof.getUint32(s + 4);
          var at = s + 8;
          if (flags & 0x1 != 0) at += 8; // base data offset
          if (flags & 0x2 != 0) at += 4; // sample description index
          if (flags & 0x8 != 0) defaultDuration = moof.getUint32(at);
        } else if (t == 'tfdt') {
          baseTime = moof.getUint8(s) == 1 ? moof.getUint64(s + 4) : moof.getUint32(s + 4);
        } else if (t == 'trun') {
          final flags = moof.getUint32(s) & 0xffffff;
          final count = moof.getUint32(s + 4);
          var at = s + 8;
          if (flags & 0x1 != 0) at += 4; // data offset
          if (flags & 0x4 != 0) at += 4; // first sample flags
          final perSample =
              (flags & 0x100 != 0 ? 4 : 0) +
              (flags & 0x200 != 0 ? 4 : 0) +
              (flags & 0x400 != 0 ? 4 : 0) +
              (flags & 0x800 != 0 ? 4 : 0);
          if (flags & 0x100 != 0) {
            for (var i = 0; i < count; i++) {
              total += moof.getUint32(at + i * perSample);
            }
          } else {
            total += count * (defaultDuration ?? defaultDurations[trackId] ?? 0);
          }
        }
      }
      if (trackId == null || baseTime == null) continue;
      final fragmentEnd = baseTime + total;
      if (fragmentEnd > (ends[trackId] ?? 0)) ends[trackId] = fragmentEnd;
    }
  }
}
