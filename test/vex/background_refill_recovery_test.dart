import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/download_operations.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/download_fixtures.dart';
import '../test_helpers/io_fakes.dart';
import '../test_helpers/prefs.dart';

class _ReplayManager extends DownloadManagerService {
  _ReplayManager(AppDatabase database)
    : super(
        database: database,
        storageService: DownloadStorageService.instance,
        clientResolver: (serverId, {clientScopeId}) => null,
      ) {
    recoveryFuture = Future<void>.value();
  }
  final replay = StreamController<DownloadProgress>.broadcast();
  final snapshotRead = Completer<void>();
  final finishMetadata = Completer<void>();
  @override
  Stream<DownloadProgress> get progressStream => replay.stream;
  @override
  Future<({Map<String, MediaItem> items, Map<String, String?> scopesByServer})> getAllPinnedMetadata({
    String? activeProfileId,
  }) async {
    snapshotRead.complete();
    await finishMetadata.future;
    return (items: <String, MediaItem>{}, scopesByServer: <String, String?>{});
  }

  @override
  void dispose() {
    replay.close();
    super.dispose();
  }
}

void main() {
  test('opening after a headless download does not replace replayed completion with an old snapshot', () async {
    resetSharedPreferencesForTest();
    final root = await Directory.systemTemp.createTemp('vex_refill_recovery_');
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(root);
    addTearDown(() async {
      PathProviderPlatform.instance = previousPaths;
      await root.delete(recursive: true);
    });
    final settings = await SettingsService.getInstance();
    await DownloadStorageService.instance.initialize(settings);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    JellyfinApiCache.initialize(db);
    final manager = _ReplayManager(db);
    final provider = DownloadProvider.forTesting(downloadManager: manager, database: db);
    addTearDown(() async {
      provider.dispose();
      manager.dispose();
      await db.close();
    });
    await provider.ensureInitialized();
    const key = 'srv:episode';
    await db.insertDownload(
      serverId: ServerId('srv'),
      ratingKey: 'episode',
      globalKey: key,
      type: 'episode',
      status: DownloadStatus.queued.index,
    );
    await db.addDownloadOwner(profileId: 'test-profile', globalKey: key);
    final refreshing = provider.refresh();
    await manager.snapshotRead.future;
    // The native downloader finished after the snapshot query, while the
    // provider was loading metadata. This is the first-open device race.
    await db.updateDownloadStatus(key, DownloadStatus.completed.index);
    manager.replay.add(DownloadProgress(globalKey: key, status: DownloadStatus.completed, progress: 100));
    await Future<void>.delayed(Duration.zero);
    manager.finishMetadata.complete();
    await refreshing;
    expect(provider.getProgress(key)?.status, DownloadStatus.completed);
    expect(provider.isDownloaded(key), isTrue);
  });
}
