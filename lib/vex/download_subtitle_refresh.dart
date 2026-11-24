// Vex fork: keep finished Jellyfin downloads' subtitles in step with the server.
//
// Upstream fetches a download's external subtitle files once, when the video
// completes, and offline playback picks tracks from the item metadata cached
// at that time. Subtitles added to the library later (Bazarr) never reach the
// copy, and a changed account default (say, always English subtitles) never
// reaches its offline track choice. About once a day this re-fetches each
// finished Jellyfin movie or episode, which rewrites that cached metadata, and
// replaces its subtitle files when the server lists one the copy lacks.
// Jellyfin numbers external subtitles before every embedded stream, so a new
// one renumbers the others: the set is replaced, never topped up.
//
// A part of download_manager_service.dart only to reach its private helpers.

part of '../services/download_manager_service.dart';

/// When the last full pass finished, in ms since the epoch.
const _vexSubtitleRefreshAt = IntPref('vex_subtitle_refresh_at');

/// The background refill runs every 6 hours; this makes about one pass a day.
const vexSubtitleRefreshInterval = Duration(hours: 20);

extension VexDownloadSubtitleRefresh on DownloadManagerService {
  static bool due(SettingsService settings, {DateTime? now}) {
    final last = DateTime.fromMillisecondsSinceEpoch(settings.read(_vexSubtitleRefreshAt));
    return (now ?? DateTime.now()).difference(last) >= vexSubtitleRefreshInterval;
  }

  /// One request per finished Jellyfin movie/episode, plus subtitle work for
  /// the ones that changed. Returns how many downloads got new subtitle files.
  /// [skipGlobalKey] is the item playing now.
  Future<int> vexRefreshDownloadedSubtitles(
    SettingsService settings, {
    bool force = false,
    String? skipGlobalKey,
  }) async {
    final now = DateTime.now();
    if (_disposed || _isOffline || (!force && !due(settings, now: now))) return 0;
    final rows = await (_database.select(
      _database.downloadedMedia,
    )..where((t) => t.status.equals(DownloadStatus.completed.index))).get();
    var replaced = 0;
    for (final row in rows) {
      // An interrupted pass leaves the stamp alone, so the next run retries.
      if (_disposed || _isOffline) return replaced;
      if (row.globalKey == skipGlobalKey || (row.type != 'movie' && row.type != 'episode')) continue;
      try {
        if (await _vexRefreshSubtitlesOf(row)) replaced++;
      } catch (e, st) {
        appLogger.w('Vex subtitle refresh failed for ${row.globalKey}', error: e, stackTrace: st);
      }
    }
    await settings.write(_vexSubtitleRefreshAt, now.millisecondsSinceEpoch);
    appLogger.i('Vex subtitle refresh: ${rows.length} downloads checked, $replaced updated');
    return replaced;
  }

  Future<bool> _vexRefreshSubtitlesOf(DownloadedMediaItem row) async {
    final videoPath = row.videoFilePath;
    if (videoPath == null) return false;
    final client = await _getClientForDownloadKey(row.globalKey);
    if (client == null || client.backend != MediaBackend.jellyfin) return false;
    final isSaf = _storageService.isSafUri(videoPath);
    // A SAF copy's sidecars live where _downloadSubtitles puts them only while SAF is the location.
    if (isSaf && !_storageService.isUsingSaf) return false;

    // fetchItem rewrites the cached row that offline playback reads its default tracks from.
    final fetched = await client.fetchItem(row.ratingKey);
    if (fetched == null) return false;
    final info = await CachedPlaybackMetadataService.fetchMediaSourceInfo(
      backend: client.backend,
      cacheServerId: client.cacheServerId,
      itemId: row.ratingKey,
      mediaIndex: row.mediaIndex,
    );
    if (info == null) return false;

    final serverId = ServerId(row.serverId);
    final directory = Directory(
      isSaf
          ? (await _storageService.getSubtitlesDirectory(serverId, row.ratingKey)).path
          : _storageService.sidecarSubtitlesDirectoryPath(await _storageService.ensureAbsolutePath(videoPath)),
    );
    final backup = Directory('${directory.path}.vex-old');
    if (await backup.exists()) await backup.delete(recursive: true);
    final stored = await _vexSidecarFiles(directory);
    final external = {
      for (final track in info.subtitleTracks)
        if (track.external) track.id,
    };
    if (stored.keys.toSet().containsAll(external)) return false;

    // Set the old files aside (outside the folder playback lists) until the new set is in.
    if (stored.isNotEmpty) {
      await backup.create(recursive: true);
      for (final file in stored.values) {
        await file.rename(path.join(backup.path, path.basename(file.path)));
      }
    }
    final metadata = _repairMetadataWithServer(fetched, serverId);
    final settled = (await _runSupplementaryDownloads(
      row.globalKey,
      metadata,
      client,
      isRepair: true,
      downloadArtwork: false,
      downloadSubtitles: true,
      record: row,
      showYear: metadata.isEpisode
          ? await _fetchShowYear(serverId, metadata.grandparentId, clientScopeId: row.clientScopeId)
          : null,
      partPaths: _partPathsOf(row),
    )).subtitles;
    // Old numbering is wrong once anything new arrived; keep it only if nothing did.
    if (!settled && stored.isNotEmpty && (await _vexSidecarFiles(directory)).isEmpty) {
      await directory.create(recursive: true);
      for (final file in await backup.list().toList()) {
        if (file is File) await file.rename(path.join(directory.path, path.basename(file.path)));
      }
    }
    if (await backup.exists()) await backup.delete(recursive: true);
    appLogger.i('Vex subtitle refresh: ${row.globalKey} ${settled ? 'updated' : 'partly updated'}');
    return settled;
  }

  /// The downloader's `{streamIndex}.{ext}` sidecars in [directory], by index.
  Future<Map<int, File>> _vexSidecarFiles(Directory directory) async {
    final files = <int, File>{};
    if (!await directory.exists()) return files;
    await for (final entity in directory.list()) {
      final index = int.tryParse(path.basenameWithoutExtension(entity.path));
      if (entity is File && index != null) files[index] = entity;
    }
    return files;
  }
}
