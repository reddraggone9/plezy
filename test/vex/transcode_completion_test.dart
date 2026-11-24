import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/download_operations.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/download_fixtures.dart';
import '../test_helpers/io_fakes.dart';
import '../test_helpers/prefs.dart';
import 'fmp4_fixture.dart';

const _globalKey = 'srv:item-1';

void main() {
  late Directory tempDir;
  late PathProviderPlatform previousPathProvider;
  late AppDatabase db;
  late DownloadManagerService manager;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    DownloadStorageService.resetForTesting();
    tempDir = await Directory.systemTemp.createTemp('vex_transcode_completion_');
    previousPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tempDir);
    await DownloadStorageService.instance.initialize(await SettingsService.getInstance());
    db = AppDatabase.forTesting(NativeDatabase(File(p.join(tempDir.path, 'downloads.sqlite'))));
    PlexApiCache.initialize(db);
    JellyfinApiCache.initialize(db);
    // 60 s runtime (Plex reports duration in milliseconds)
    await PlexApiCache.instance.put(ServerId('srv'), '/library/metadata/item-1', {
      'MediaContainer': {
        'Metadata': [
          {'ratingKey': 'item-1', 'type': 'movie', 'title': 'Movie', 'duration': 60000},
        ],
      },
    });
    await db.insertDownload(
      serverId: ServerId('srv'),
      ratingKey: 'item-1',
      globalKey: _globalKey,
      type: 'movie',
      status: DownloadStatus.downloading.index,
    );
    await db.updateBgTaskId(_globalKey, 'current-task');
    await db.addToQueue(mediaGlobalKey: _globalKey, downloadSubtitles: false, downloadArtwork: false);
    manager = DownloadManagerService(
      database: db,
      storageService: DownloadStorageService.instance,
      clientResolver: (serverId, {clientScopeId}) => null,
      downloadsSupportedOverride: false,
    );
  });

  tearDown(() async {
    manager.dispose();
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPathProvider;
    await tempDir.delete(recursive: true);
  });

  Future<DownloadTask> transcodeTask({required int seconds, bool allowPause = false}) async {
    final task = DownloadTask(
      taskId: 'current-task',
      url: 'https://example.test/Videos/item-1/stream.mp4',
      filename: 'video.mp4',
      directory: p.join(tempDir.path, 'media'),
      baseDirectory: BaseDirectory.root,
      metaData: _globalKey,
      allowPause: allowPause,
    );
    final file = File(await task.filePath());
    await file.parent.create(recursive: true);
    await file.writeAsBytes(fragmentedMp4(fragments: seconds ~/ 2));
    return task;
  }

  test('a transcode the server ended early is not recorded as complete', () async {
    final task = await transcodeTask(seconds: 40);

    await manager.debugHandleTaskStatus(TaskStatusUpdate(task, TaskStatus.complete));

    final row = await db.getDownloadedMedia(_globalKey);
    expect(row?.status, DownloadStatus.failed.index);
    expect(row?.videoFilePath, isNull);
    expect(File(await task.filePath()).existsSync(), isFalse);
  });

  test('a full-length transcode completes', () async {
    final task = await transcodeTask(seconds: 60);

    await manager.debugHandleTaskStatus(TaskStatusUpdate(task, TaskStatus.complete));

    final row = await db.getDownloadedMedia(_globalKey);
    expect(row?.status, DownloadStatus.completed.index);
    expect(row?.videoFilePath, isNotNull);
  });

  test('an original-file download (pausable) is not checked', () async {
    final task = await transcodeTask(seconds: 40, allowPause: true);

    await manager.debugHandleTaskStatus(TaskStatusUpdate(task, TaskStatus.complete));

    expect((await db.getDownloadedMedia(_globalKey))?.status, DownloadStatus.completed.index);
  });
}
