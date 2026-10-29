// Vex fork: device-compatible playback for Jellyfin.
//
// Upstream Plezy plays "Original" as the untouched file even when the device
// has no hardware decoder for it (an AV1 4K60 file on a Fire HD 10 plays as a
// slideshow in software). This fork measures what the hardware decoders and
// the display can do, sends that to Jellyfin as `CodecProfiles`, and plays the
// server's transcode whenever the server says the original does not fit.
//
// Kept in one app-owned file so the hooks in upstream's busy files stay
// one-liners and the fork rebases cleanly.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/settings_service.dart';
import '../utils/device_channel.dart';

/// Sent as `MaxStreamingBitrate` in Auto mode. An omitted cap is not
/// "unlimited" to Jellyfin: it falls back to a low default and refuses direct
/// play of any remux (`ContainerBitrateExceedsLimit`).
const vexUnlimitedBitrate = 1000000000;

/// Fork-owned preferences.
abstract final class VexPrefs {
  /// "Original" quality becomes "Auto (device-compatible)": play the file
  /// when the hardware can decode it, otherwise the server's transcode.
  static const autoCompatible = BoolPref('vex_auto_compatible', defaultValue: true);

  /// Only where the fork's decoder probe answered (Android); elsewhere
  /// Original keeps upstream's behaviour.
  static bool get autoCompatibleEnabled =>
      VexDeviceLimits.current != null && (SettingsService.instanceOrNull?.read(autoCompatible) ?? true);

  /// Downloads: keep the original when the hardware can play it, otherwise
  /// download a server transcode sized for this device ("Auto").
  static const downloadAutoCompatible = BoolPref('vex_download_auto_compatible', defaultValue: true);

  static bool get downloadAutoCompatibleEnabled =>
      VexDeviceLimits.current != null && (SettingsService.instanceOrNull?.read(downloadAutoCompatible) ?? true);
}

/// Bitrate cap for a device-compatible download transcode (1080p H.264/HEVC).
const vexDownloadBitrate = 8000000;

/// Progressive MP4 transcode used for device-compatible downloads: a single
/// file the downloader can fetch, H.264 first because every Android device
/// plays it; HEVC only when the hardware decodes it.
Map<String, Object?> vexDownloadTranscodingProfile([VexDeviceLimits? limits]) {
  limits ??= VexDeviceLimits.current;
  return {
    'Type': 'Video',
    'Container': 'mp4',
    'Protocol': 'http',
    'Context': 'Streaming',
    'VideoCodec': ['h264', if (limits?.codecs.containsKey('hevc') ?? false) 'hevc'].join(','),
    'AudioCodec': 'aac,mp3,ac3,eac3',
    'MaxAudioChannels': '6',
  };
}

/// One hardware decoder's limits, as reported by `DecoderLimits.kt`.
@immutable
class VexCodecLimits {
  const VexCodecLimits({
    required this.maxWidth,
    required this.maxHeight,
    this.uhd60 = false,
    this.uhd30 = false,
    this.fhd60 = false,
    this.fhd30 = false,
    this.tenBit = false,
  });

  final int maxWidth;
  final int maxHeight;
  final bool uhd60;
  final bool uhd30;
  final bool fhd60;
  final bool fhd30;
  final bool tenBit;

  static VexCodecLimits? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final w = raw['maxWidth'];
    final h = raw['maxHeight'];
    if (w is! int || h is! int || w <= 0 || h <= 0) return null;
    return VexCodecLimits(
      maxWidth: w,
      maxHeight: h,
      uhd60: raw['uhd60'] == true,
      uhd30: raw['uhd30'] == true,
      fhd60: raw['fhd60'] == true,
      fhd30: raw['fhd30'] == true,
      tenBit: raw['tenBit'] == true,
    );
  }
}

/// Hardware decoders plus display, or nothing on platforms that do not answer
/// (desktop, iOS): there the fork changes nothing.
@immutable
class VexDeviceLimits {
  const VexDeviceLimits({
    required this.codecs,
    this.displayLong = 0,
    this.displayShort = 0,
    this.displayHdr = const [],
  });

  /// Codec id (`h264`, `hevc`, `av1`, `vp9`, `vp8`, `mpeg2video`, `mpeg4`) to
  /// its hardware decoder. A missing codec has no hardware decoder.
  final Map<String, VexCodecLimits> codecs;
  final int displayLong;
  final int displayShort;
  final List<String> displayHdr;

  bool get hasDisplay => displayLong > 0 && displayShort > 0;

  static VexDeviceLimits? fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) return null;
    final codecs = <String, VexCodecLimits>{};
    final rawCodecs = raw['codecs'];
    if (rawCodecs is Map) {
      for (final entry in rawCodecs.entries) {
        final limits = VexCodecLimits.fromMap(entry.value);
        if (limits != null) codecs['${entry.key}'] = limits;
      }
    }
    final display = raw['display'];
    int dim(String key) => display is Map && display[key] is int ? display[key] as int : 0;
    return VexDeviceLimits(
      codecs: codecs,
      displayLong: dim('longSide'),
      displayShort: dim('shortSide'),
      displayHdr: display is Map && display['hdr'] is List ? [for (final t in display['hdr'] as List) '$t'] : const [],
    );
  }

  static VexDeviceLimits? _current;

  /// Latched once at startup, beside upstream's own decoder probe.
  static VexDeviceLimits? get current => _current;

  static Future<void> load() async {
    try {
      _current = fromMap(await deviceChannel.invokeMapMethod<Object?, Object?>('vexGetDecoderLimits'));
    } on MissingPluginException {
      _current = null;
    } on PlatformException {
      _current = null;
    }
  }

  @visibleForTesting
  static set debugCurrent(VexDeviceLimits? value) => _current = value;
}

/// Codecs a heavy software decode would make unwatchable: without a hardware
/// decoder they must not direct-play. HEVC and AV1 are already gated by
/// upstream's probe; VP9 is not.
const _hardwareOnlyCodecs = {'vp9', 'hevc', 'h265', 'av1'};

/// Whether [codec] may stay in the direct-play list. True everywhere the
/// fork's probe did not run.
bool vexAllowsDirectPlayCodec(String codec, [VexDeviceLimits? limits]) {
  limits ??= VexDeviceLimits.current;
  if (limits == null || !_hardwareOnlyCodecs.contains(codec)) return true;
  return limits.codecs.containsKey(codec == 'h265' ? 'hevc' : codec);
}

Map<String, Object?> _cond(String condition, String property, Object value) => {
  'Condition': condition,
  'Property': property,
  'Value': '$value',
  'IsRequired': false,
};

/// Jellyfin `CodecProfiles` for [limits]: per hardware codec, the size, frame
/// rate, bit depth and (on an SDR panel) dynamic range it can decode, capped
/// to the display; plus a codec-less display cap for everything else. The
/// server applies the same conditions to a transcode, so the output lands at
/// display size in a codec the hardware decodes, tone-mapped on an SDR panel.
List<Map<String, Object?>> vexJellyfinCodecProfiles([VexDeviceLimits? limits]) {
  limits ??= VexDeviceLimits.current;
  if (limits == null || !VexPrefs.autoCompatibleEnabled) return const [];
  return buildVexJellyfinCodecProfiles(limits);
}

@visibleForTesting
List<Map<String, Object?>> buildVexJellyfinCodecProfiles(VexDeviceLimits limits) {
  final profiles = <Map<String, Object?>>[];
  final sdrOnly = limits.displayHdr.isEmpty;
  for (final MapEntry(key: codec, value: hw) in limits.codecs.entries) {
    var width = hw.maxWidth;
    var height = hw.maxHeight;
    if (limits.hasDisplay) {
      if (limits.displayLong < width) width = limits.displayLong;
      if (limits.displayShort < height) height = limits.displayShort;
    }
    // A WUXGA panel (1920x1200) is still the 1080p decode class.
    final aboveFhd = width * height > 1920 * 1200;
    final fps = aboveFhd ? (hw.uhd60 ? 60 : 30) : (hw.fhd60 ? 60 : 30);
    profiles.add({
      'Type': 'Video',
      'Codec': codec == 'hevc' ? 'hevc,h265' : codec,
      'Conditions': [
        _cond('LessThanEqual', 'Width', width),
        _cond('LessThanEqual', 'Height', height),
        // +1 so 59.94/60.0 (and container rounding) still fits a 60 fps decoder.
        _cond('LessThanEqual', 'VideoFramerate', fps + 1),
        _cond('LessThanEqual', 'VideoBitDepth', hw.tenBit ? 10 : 8),
        if (sdrOnly) _cond('EqualsAny', 'VideoRangeType', 'SDR'),
      ],
    });
  }
  if (limits.hasDisplay) {
    profiles.add({
      'Type': 'Video',
      'Conditions': [
        _cond('LessThanEqual', 'Width', limits.displayLong),
        _cond('LessThanEqual', 'Height', limits.displayShort),
      ],
    });
  }
  return profiles;
}

/// Whether Android reports the active network as metered (a phone hotspot,
/// cellular). False where the platform does not answer.
Future<bool> vexActiveNetworkMetered() async {
  try {
    return await deviceChannel.invokeMethod<bool>('vexIsActiveNetworkMetered') ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Items whose direct play failed this session: their next open asks the
/// server for a transcode only.
abstract final class VexForcedTranscode {
  static final Set<String> _items = {};

  static bool isForced(String itemId) => _items.contains(itemId);

  /// Returns false when [itemId] was already forced (one retry only).
  static bool mark(String itemId) => _items.add(itemId);

  @visibleForTesting
  static void debugReset() => _items.clear();
}
