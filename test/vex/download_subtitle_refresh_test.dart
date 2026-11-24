import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/database/download_operations.dart';
import 'package:plezy/media/download_resolution.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/services/cached_playback_metadata_service.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../test_helpers/download_fixtures.dart';
import '../test_helpers/io_fakes.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

const _scope = 'srv/user1';
const _endpoint = '/Users/user1/Items/item-1';

Map<String, dynamic> _stream(int index, String type, {bool external = false}) => {
  'Index': index,
  'Type': type,
  'Language': 'eng',
  'Codec': type == 'Subtitle' ? 'subrip' : null,
  'IsExternal': external,
};

/// The Jellyfin item as the server lists it: external subtitles first.
Map<String, dynamic> _item(List<Map<String, dynamic>> streams, {int? defaultSubtitle}) => {
  'Id': 'item-1',
  'Type': 'Movie',
  'Name': 'Movie',
  'MediaSources': [
    {'Id': 'item-1', 'MediaStreams': streams, 'DefaultSubtitleStreamIndex': defaultSubtitle},
  ],
};

class _Server implements MediaServerClient, ScopedMediaServerClient {
  _Server(this.item, this.subtitles);

  Map<String, dynamic> item;
  List<DownloadSubtitleSpec> subtitles;
  int fetches = 0;
  int resolves = 0;

  @override
  ServerId get serverId => ServerId('srv');
  @override
  String get scopedServerId => _scope;
  @override
  String? get serverName => 'Server';
  @override
  MediaBackend get backend => MediaBackend.jellyfin;

  @override
  Future<MediaItem?> fetchItem(String id) async {
    fetches++;
    await JellyfinApiCache.instance.put(ServerId(_scope), _endpoint, item);
    return testMediaItem(id: 'item-1', backend: MediaBackend.jellyfin, kind: MediaKind.movie, title: 'Movie');
  }

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    resolves++;
    return DownloadResolution(videoUrl: 'https://example.test/video', externalSubtitles: subtitles);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SubtitleHttp extends http.BaseClient {
  bool fail = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async => http.StreamedResponse(
    Stream.value(utf8.encode(fail ? 'error' : 'sub-${request.url.pathSegments.last}')),
    fail ? 500 : 200,
    request: request,
  );
}

DownloadSubtitleSpec _spec(int index) =>
    DownloadSubtitleSpec(id: index, url: 'https://example.test/subtitle/$index', codec: 'srt');

void main() {
  late Directory temp;
  late PathProviderPlatform previousPaths;
  late AppDatabase db;
  late SettingsService settings;
  late Directory subs;
  late _Server server;
  late _SubtitleHttp subtitleHttp;
  late DownloadManagerService manager;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    DownloadStorageService.resetForTesting();
    temp = await Directory.systemTemp.createTemp('vex_subtitle_refresh_test_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(temp);
    settings = await SettingsService.getInstance();
    await DownloadStorageService.instance.initialize(settings);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    JellyfinApiCache.initialize(db);

    // Downloaded as a transcode before any external subtitle existed: its
    // embedded text track (then stream 2) was saved as 2.srt.
    await db.insertDownload(
      serverId: ServerId('srv'),
      ratingKey: 'item-1',
      globalKey: 'srv:item-1',
      type: 'movie',
      status: DownloadStatus.completed.index,
    );
    await db.updateVideoFilePath('srv:item-1', 'downloads/srv/item-1/video.mp4');
    final storage = DownloadStorageService.instance;
    subs = Directory(
      storage.sidecarSubtitlesDirectoryPath(await storage.ensureAbsolutePath('downloads/srv/item-1/video.mp4')),
    );
    await subs.create(recursive: true);
    await File(p.join(subs.path, '2.srt')).writeAsString('old embedded');

    // Bazarr then added an English .srt: Jellyfin lists it first and renumbers the rest.
    server = _Server(
      _item([
        _stream(0, 'Subtitle', external: true),
        _stream(1, 'Video'),
        _stream(2, 'Audio'),
        _stream(3, 'Subtitle'),
      ], defaultSubtitle: 0),
      [_spec(0), _spec(3)],
    );
    subtitleHttp = _SubtitleHttp();
    manager = DownloadManagerService(
      database: db,
      storageService: storage,
      clientResolver: (serverId, {clientScopeId}) => server,
      http: MediaServerHttpClient(client: subtitleHttp),
      downloadsSupportedOverride: false,
    );
  });

  tearDown(() async {
    manager.dispose();
    await db.close();
    DownloadStorageService.resetForTesting();
    SettingsService.resetForTesting();
    PathProviderPlatform.instance = previousPaths;
    await temp.delete(recursive: true);
  });

  Map<String, String> files() => {
    for (final f in subs.listSync().whereType<File>()) p.basename(f.path): f.readAsStringSync(),
  };

  test('a subtitle added after the download replaces the renumbered set and refreshes offline defaults', () async {
    expect(await manager.vexRefreshDownloadedSubtitles(settings), 1);

    expect(files(), {'0.srt': 'sub-0', '3.srt': 'sub-3'});
    expect(Directory('${subs.path}.vex-old').existsSync(), isFalse);
    final info = await CachedPlaybackMetadataService.fetchMediaSourceInfo(
      backend: MediaBackend.jellyfin,
      cacheServerId: _scope,
      itemId: 'item-1',
    );
    expect(info!.subtitleTracks.where((t) => t.selected).map((t) => t.id), [0]);
  });

  test('runs about once a day and leaves an up-to-date download alone', () async {
    await manager.vexRefreshDownloadedSubtitles(settings);
    expect(await manager.vexRefreshDownloadedSubtitles(settings), 0);
    expect(server.fetches, 1);

    expect(await manager.vexRefreshDownloadedSubtitles(settings, force: true), 0);
    expect(server.fetches, 2);
    expect(server.resolves, 1);
    expect(files(), {'0.srt': 'sub-0', '3.srt': 'sub-3'});
  });

  test('a failed fetch keeps the old files and retries on the next pass', () async {
    subtitleHttp.fail = true;
    expect(await manager.vexRefreshDownloadedSubtitles(settings), 0);
    expect(files(), {'2.srt': 'old embedded'});
    expect(Directory('${subs.path}.vex-old').existsSync(), isFalse);

    subtitleHttp.fail = false;
    expect(await manager.vexRefreshDownloadedSubtitles(settings, force: true), 1);
    expect(files(), {'0.srt': 'sub-0', '3.srt': 'sub-3'});
  });

  test('skips the item that is playing', () async {
    expect(await manager.vexRefreshDownloadedSubtitles(settings, skipGlobalKey: 'srv:item-1'), 0);
    expect(server.fetches, 0);
  });
}
