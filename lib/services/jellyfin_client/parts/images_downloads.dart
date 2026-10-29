part of '../../jellyfin_client.dart';

mixin _JellyfinImageDownloadMethods on _JellyfinClientInternals {
  /// [cover] is accepted for interface parity and ignored: `maxWidth`/
  /// `maxHeight` already scale the long axis to fit inside the box, so
  /// Jellyfin never overshoots the way Plex's `minSize=1` transcode does.
  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) {
    if (path == null || path.isEmpty) return '';
    final uri = JellyfinImageAbsolutizer.joinUri(baseUrl: connection.baseUrl, urlOrPath: path);
    final params = Map<String, String>.from(uri.queryParameters);
    if (width != null && !params.containsKey('maxWidth') && !params.containsKey('MaxWidth')) {
      params['maxWidth'] = '$width';
    }
    if (height != null && !params.containsKey('maxHeight') && !params.containsKey('MaxHeight')) {
      params['maxHeight'] = '$height';
    }
    params.putIfAbsent('api_key', () => connection.accessToken);
    return uri.replace(queryParameters: params).toString();
  }

  /// Jellyfin doesn't expose an external-URL proxy endpoint comparable to
  /// Plex's `/photo/:/transcode?url=...`. External URLs pass through.
  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) => url;

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    final bundle = await fetchPlaybackBundle(item.id, sourceIndex: mediaIndex, sourceId: mediaSourceId);
    final selectedSourceId = bundle?.selectedSourceId;
    final requestedSourceId = mediaSourceId?.trim();
    if (requestedSourceId != null &&
        requestedSourceId.isNotEmpty &&
        selectedSourceId?.toLowerCase() != requestedSourceId.toLowerCase()) {
      throw StateError('Requested Jellyfin download source is no longer available');
    }

    // Tracks download from the audio static-stream endpoint and have no
    // subtitle sidecars to enumerate.
    if (item.kind == MediaKind.track) {
      final audioUrl = buildAudioDirectStreamUrl(
        item.id,
        container: bundle?.container,
        mediaSourceId: bundle?.pinnedSourceId,
      );
      return DownloadResolution(videoUrl: audioUrl, mediaSourceId: selectedSourceId, externalSubtitles: const []);
    }

    // Direct-stream the selected original file. Jellyfin's `Static=true`
    // skips the transcoder so the byte-for-byte source lands on disk.
    final staticUrl = buildDirectStreamUrl(
      item.id,
      container: bundle?.container,
      mediaSourceId: bundle?.pinnedSourceId,
    );
    // Vex fork: a server transcode when the hardware cannot play the original.
    final vexTranscodeUrl = await _vexDeviceCompatibleDownloadUrl(item.id, selectedSourceId);
    final videoUrl = vexTranscodeUrl ?? staticUrl;
    final vexTranscoded = vexTranscodeUrl != null;

    // External subtitle sidecars are listed in the per-source MediaStreams.
    // PlaybackInfo gives us the canonical view including DeliveryUrl when
    // the server has pre-computed one; fall back to the documented stream
    // URL pattern otherwise. Negotiation is enrichment only: the static
    // stream URL above remains valid without it.
    final subtitles = <DownloadSubtitleSpec>[];
    Map<String, dynamic> playbackInfo;
    try {
      playbackInfo = await getPlaybackInfo(item.id, mediaSourceId: selectedSourceId);
    } catch (error, stackTrace) {
      if (!_canUseJellyfinStaticStreamFallback(error)) rethrow;
      appLogger.w(
        'Jellyfin download subtitle enrichment unavailable; using the static stream',
        error: error,
        stackTrace: stackTrace,
      );
      return DownloadResolution(
        videoUrl: videoUrl,
        mediaSourceId: selectedSourceId,
        externalSubtitlesResolved: false,
        vexTranscoded: vexTranscoded,
      );
    }

    final source = _selectDownloadMediaSource(playbackInfo['MediaSources'] as List, selectedSourceId, mediaIndex);
    if (source == null) {
      appLogger.w('Jellyfin download subtitle enrichment returned no usable source; using the static stream');
      return DownloadResolution(
        videoUrl: videoUrl,
        mediaSourceId: selectedSourceId,
        externalSubtitlesResolved: false,
        vexTranscoded: vexTranscoded,
      );
    }
    if (source['MediaStreams'] is! List) {
      appLogger.w('Jellyfin download subtitle enrichment returned malformed streams; using the static stream');
      return DownloadResolution(
        videoUrl: videoUrl,
        mediaSourceId: selectedSourceId,
        externalSubtitlesResolved: false,
        vexTranscoded: vexTranscoded,
      );
    }

    final streams = source['MediaStreams'] as List;
    final rawMediaSourceId = source['Id'];
    if (rawMediaSourceId != null && rawMediaSourceId is! String) {
      appLogger.w('Jellyfin download subtitle enrichment returned an invalid source id; using the static stream');
      return DownloadResolution(
        videoUrl: videoUrl,
        mediaSourceId: selectedSourceId,
        externalSubtitlesResolved: false,
        vexTranscoded: vexTranscoded,
      );
    }
    final subtitleMediaSourceId = rawMediaSourceId as String? ?? item.id;
    for (final raw in streams) {
      if (raw is! Map<String, dynamic>) continue;
      if (raw['Type'] != 'Subtitle') continue;
      final fields = parseJellyfinStreamFields(raw);
      // Vex fork: a transcoded MP4 drops embedded text subtitles, so fetch those as files too.
      if (!fields.isExternalFile && !(vexTranscoded && CodecUtils.isTextSubtitleCodec(fields.codec))) continue;
      final index = raw['Index'];
      if (index is! int) continue;
      final codec = fields.codec?.toLowerCase();
      final delivery = fields.deliveryUrl;
      final streamFile = _segment('Stream.${CodecUtils.getSubtitleExtension(codec)}');
      final url = _withApiKey(
        delivery != null && delivery.isNotEmpty
            ? delivery
            : '/Videos/${_segment(item.id)}/${_segment(subtitleMediaSourceId)}/Subtitles/$index/$streamFile',
      );
      subtitles.add(
        DownloadSubtitleSpec(
          id: index,
          url: url,
          codec: codec,
          language: fields.language,
          languageCode: fields.languageCode,
          forced: fields.isForced,
          displayTitle: fields.displayTitle,
        ),
      );
    }

    return DownloadResolution(
      videoUrl: videoUrl,
      mediaSourceId: selectedSourceId,
      externalSubtitles: subtitles,
      vexTranscoded: vexTranscoded,
    );
  }

  /// Vex fork: the progressive MP4 transcode URL for [itemId] when the device
  /// cannot hardware-decode the selected source, or null to keep the original.
  /// Decided with no bitrate cap (the original is kept whenever it plays), then
  /// re-negotiated at [vexDownloadBitrate] for the file actually downloaded.
  Future<String?> _vexDeviceCompatibleDownloadUrl(String itemId, String? sourceId) async {
    if (!VexPrefs.downloadAutoCompatibleEnabled) return null;
    try {
      Map<String, dynamic>? pick(Map<String, dynamic> info) =>
          _selectDownloadMediaSource(info['MediaSources'] as List? ?? const [], sourceId, 0);
      final decision = pick(
        await getPlaybackInfo(
          itemId,
          mediaSourceId: sourceId,
          maxStreamingBitrate: vexUnlimitedBitrate,
          vexTranscodingProfile: vexDownloadTranscodingProfile(),
        ),
      );
      if (decision == null || decision['SupportsDirectPlay'] == true) return null;
      final transcode = pick(
        await getPlaybackInfo(
          itemId,
          mediaSourceId: sourceId,
          maxStreamingBitrate: vexDownloadBitrate,
          enableDirectPlay: false,
          enableDirectStream: false,
          vexTranscodingProfile: vexDownloadTranscodingProfile(),
        ),
      );
      final url = transcode?['TranscodingUrl'];
      if (url is! String || url.isEmpty) return null;
      appLogger.i('Vex: downloading $itemId as a device-compatible transcode');
      return _withApiKey(url);
    } catch (error, stackTrace) {
      appLogger.w(
        'Vex: device-compatible download negotiation failed; downloading the original',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Map<String, dynamic>? _selectDownloadMediaSource(List<dynamic> sources, String? selectedSourceId, int mediaIndex) {
    if (sources.isEmpty) return null;
    final requestedSourceId = selectedSourceId?.trim();
    if (requestedSourceId != null && requestedSourceId.isNotEmpty) {
      for (final source in sources) {
        if (source is! Map<String, dynamic>) continue;
        final sourceId = source['Id'];
        if (sourceId is String && sourceId.toLowerCase() == requestedSourceId.toLowerCase()) {
          return source;
        }
      }
      return null;
    }
    final source = mediaIndex >= 0 && mediaIndex < sources.length ? sources[mediaIndex] : sources.first;
    if (source is! Map<String, dynamic>) return null;
    return source;
  }

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) {
    // Jellyfin paths flow through `_absolutizeImagePath` at the mapper
    // boundary, so artwork fields on the [MediaItem] are already absolute
    // URLs. buildArtworkSpecs strips auth query params from localKey so the
    // storage layer never hashes or persists access tokens.
    return buildArtworkSpecs(item, (path) => path);
  }
}
