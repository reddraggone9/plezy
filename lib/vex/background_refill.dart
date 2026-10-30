// Vex fork: reuse upstream's profile binding and Keep Synced execution without a UI.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../connection/connection_registry.dart';
import '../database/app_database.dart';
import '../profiles/active_profile_binder.dart';
import '../profiles/active_profile_provider.dart';
import '../profiles/plex_home_service.dart';
import '../profiles/profile_connection_registry.dart';
import '../profiles/profile_registry.dart';
import '../providers/download_provider.dart';
import '../providers/multi_server_provider.dart';
import '../services/jellyfin_api_cache.dart';
import '../services/plex_api_cache.dart';
import '../services/data_aggregation_service.dart';
import '../services/download_manager_service.dart';
import '../services/download_storage_service.dart';
import '../services/multi_server_manager.dart';
import '../services/settings_service.dart';
import '../services/storage_service.dart';
import '../utils/app_logger.dart';
import '../utils/certificate_trust.dart';
import 'vex_playback.dart';

abstract final class VexBackgroundRefill {
  static const channel = MethodChannel('com.plezy.vex/refill');
  static Future<void>? _running;

  // Main startup waits if a headless pass was already using the database and
  // downloader. Never install two sets of downloader callbacks concurrently.
  static Future<void> awaitHeadless() async {
    if (Platform.isAndroid) await channel.invokeMethod<void>('awaitHeadless');
  }

  static void attach(
    DownloadProvider provider,
    MultiServerManager servers,
    SettingsService settings, {
    required String? Function() activeGlobalKey,
    required Future<void> Function() waitForQueueHandoff,
  }) {
    if (!Platform.isAndroid) return;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'refill') throw MissingPluginException();
      await refill(provider, servers, settings, activeGlobalKey: activeGlobalKey());
      await waitForQueueHandoff();
      return true;
    });
    unawaited(channel.invokeMethod<void>('schedule'));
  }

  static Future<void> refill(
    DownloadProvider provider,
    MultiServerManager servers,
    SettingsService settings, {
    String? activeGlobalKey,
  }) => _running ??= _refill(
    provider,
    servers,
    settings,
    activeGlobalKey: activeGlobalKey,
  ).whenComplete(() => _running = null);

  static Future<void> _refill(
    DownloadProvider provider,
    MultiServerManager servers,
    SettingsService settings, {
    String? activeGlobalKey,
  }) async {
    // Use exactly upstream's gate (Wi-Fi/Ethernet, not unmetered), before
    // deleting anything as well as before queueing. The executor rechecks it
    // and DownloadManagerService retains requiresWiFi on each native task.
    if (await DownloadManagerService.shouldBlockDownloadOnCellular()) return;
    await provider.ensureProfileInitialized();
    await provider.refreshMetadataFromCache();
    if (settings.read(SettingsService.autoRemoveWatchedDownloads)) {
      await provider.autoDeleteWatchedDownloads(activeGlobalKey: activeGlobalKey);
    }
    final queued = await provider.executeSyncRules(servers, force: true);
    appLogger.i('Vex background refill: ${queued.join(', ')}');
  }

  static Future<void> runHeadless() async {
    WidgetsFlutterBinding.ensureInitialized();
    var success = false;
    AppDatabase? database;
    DownloadProvider? downloads;
    DownloadManagerService? manager;
    MultiServerManager? servers;
    ActiveProfileProvider? active;
    ActiveProfileBinder? binder;
    MultiServerProvider? multi;
    PlexHomeService? home;
    try {
      final settings = await SettingsService.getInstance();
      if (await DownloadManagerService.shouldBlockDownloadOnCellular()) {
        success = true;
        return;
      }
      await CertificateTrust.loadUserAuthorities();
      await VexDeviceLimits.load();
      final storage = await StorageService.getInstance();
      database = (await AppDatabase.open()).database;
      final connections = ConnectionRegistry(database);
      final profileConnections = ProfileConnectionRegistry(database);
      home = PlexHomeService(connections: connections, profileConnections: profileConnections, storage: storage);
      await home.hydrate();
      active = ActiveProfileProvider(
        registry: ProfileRegistry(database),
        plexHome: home,
        connections: connections,
        profileConnections: profileConnections,
        storage: storage,
      );
      await active.initialize();
      // Don't connect servers (or refresh credentials) when there is no work.
      final profileId = active.activeId;
      if (profileId == null || !(await database.getSyncRules(profileId: profileId)).any((r) => r.enabled)) {
        success = true;
        return;
      }
      servers = MultiServerManager()..onJellyfinConnectionUpdated = connections.upsert;
      multi = MultiServerProvider(servers, DataAggregationService(servers));
      binder = ActiveProfileBinder(
        activeProfile: active,
        connections: connections,
        profileConnections: profileConnections,
        serverManager: servers,
        multiServerProvider: multi,
        pinPrompt: (_, {errorMessage}) async => null,
      );
      binder.start(allowInitialPinPrompt: false);
      if (!await active.awaitBindingSettle()) throw StateError('Background profile bind did not succeed');
      PlexApiCache.initialize(database);
      JellyfinApiCache.initialize(database);
      await DownloadStorageService.instance.initialize(settings);
      manager = DownloadManagerService(
        database: database,
        storageService: DownloadStorageService.instance,
        clientResolver: servers.resolveDownloadClient,
      );
      manager.recoveryFuture = manager.recoverInterruptedDownloads();
      downloads = DownloadProvider(downloadManager: manager, database: database)..setActiveProfileId(profileId);
      await refill(downloads, servers, settings);
      // queueDownload starts a non-blocking drain. Don't destroy its engine
      // until every prepared video has been handed to background_downloader.
      for (final client in servers.onlineClients.values.take(1)) {
        await manager.handoffQueuedDownloads(client);
      }
      await manager.waitForQueueHandoff();
      success = true;
    } catch (error, stack) {
      appLogger.w('Vex background refill failed', error: error, stackTrace: stack);
    } finally {
      await manager?.waitForQueueHandoff();
      downloads?.dispose();
      manager?.dispose();
      binder?.dispose();
      active?.dispose();
      multi?.dispose();
      await servers?.shutdown();
      await home?.dispose();
      await database?.close();
      await channel.invokeMethod<void>('finish', success);
    }
  }
}
