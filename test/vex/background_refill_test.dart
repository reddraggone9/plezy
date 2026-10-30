import 'dart:async';

import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/vex/background_refill.dart';

import '../test_helpers/prefs.dart';

class _Link extends ConnectivityPlatform {
  _Link(this.links);
  final List<ConnectivityResult> links;
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => links;
}

class _Downloads extends ChangeNotifier implements DownloadProvider {
  final calls = <String>[];
  Completer<void>? gate;
  String? protectedKey;

  @override
  Future<void> ensureProfileInitialized() async {
    calls.add('profile');
    await gate?.future;
  }

  @override
  Future<void> refreshMetadataFromCache() async => calls.add('metadata');
  @override
  Future<List<String>> autoDeleteWatchedDownloads({String? activeGlobalKey}) async {
    protectedKey = activeGlobalKey;
    calls.add('delete');
    return [];
  }

  @override
  Future<List<String>> executeSyncRules(MultiServerManager servers, {bool force = false}) async {
    expect(force, isTrue);
    calls.add('sync');
    return ['Show (1)'];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    final old = ConnectivityPlatform.instance;
    addTearDown(() => ConnectivityPlatform.instance = old);
  });

  for (final link in [ConnectivityResult.wifi, ConnectivityResult.ethernet, ConnectivityResult.mobile]) {
    for (final wifiOnly in [true, false]) {
      test('background refill respects upstream Wi-Fi policy: $link, wifiOnly=$wifiOnly', () async {
        ConnectivityPlatform.instance = _Link([link]);
        final settings = await SettingsService.getInstance();
        await settings.write(SettingsService.downloadOnWifiOnly, wifiOnly);
        await settings.write(SettingsService.autoRemoveWatchedDownloads, true);
        final downloads = _Downloads();
        final servers = MultiServerManager();
        addTearDown(downloads.dispose);
        addTearDown(servers.dispose);
        await VexBackgroundRefill.refill(downloads, servers, settings, activeGlobalKey: 'playing');
        final blocked = wifiOnly && link == ConnectivityResult.mobile;
        expect(downloads.calls, blocked ? isEmpty : ['profile', 'metadata', 'delete', 'sync']);
        if (!blocked) expect(downloads.protectedKey, 'playing');
      });
    }
  }

  test('coalesces overlapping worker passes and waits for profile reload', () async {
    ConnectivityPlatform.instance = _Link([ConnectivityResult.wifi]);
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.autoRemoveWatchedDownloads, false);
    final downloads = _Downloads()..gate = Completer<void>();
    final servers = MultiServerManager();
    addTearDown(downloads.dispose);
    addTearDown(servers.dispose);
    final first = VexBackgroundRefill.refill(downloads, servers, settings);
    final second = VexBackgroundRefill.refill(downloads, servers, settings);
    await Future<void>.delayed(Duration.zero);
    expect(downloads.calls, ['profile']);
    downloads.gate!.complete();
    await Future.wait([first, second]);
    expect(downloads.calls, ['profile', 'metadata', 'sync']);
  });
}
