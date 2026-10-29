import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/jellyfin_client.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/utils/device_identity.dart';
import 'package:plezy/vex/vex_playback.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/http_fixtures.dart';
import '../test_helpers/media_items.dart';

const _fire = VexDeviceLimits(
  codecs: {
    'h264': VexCodecLimits(maxWidth: 4096, maxHeight: 2304, fhd60: true),
    'hevc': VexCodecLimits(maxWidth: 4096, maxHeight: 2304, fhd60: true),
  },
  displayLong: 1920,
  displayShort: 1200,
);

/// A server that offers a transcode and reports [directPlay] for the source.
({JellyfinClient client, List<http.Request> playbackInfo}) _server({required bool directPlay}) {
  final playbackInfo = <http.Request>[];
  final client = JellyfinClient.forTesting(
    connection: testJellyfinConnection(
      baseUrl: 'https://jf.example.com',
      userName: 'lee',
      accessToken: 'tok',
      deviceId: 'dev',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    ),
    httpClient: MockClient((request) async {
      if (request.url.path == '/Users/user-1/Items/item-1') {
        return jsonResponse({
          'Id': 'item-1',
          'Type': 'Movie',
          'Name': 'Movie',
          'MediaSources': [
            {
              'Id': 'src-1',
              'Container': 'mkv',
              'MediaStreams': [
                {'Index': 0, 'Type': 'Video'},
              ],
            },
          ],
        });
      }
      if (request.url.path == '/Items/item-1/PlaybackInfo') {
        playbackInfo.add(request);
        return jsonResponse({
          'PlaySessionId': 'ps',
          'MediaSources': [
            {
              'Id': 'src-1',
              'SupportsDirectPlay': directPlay,
              'TranscodingUrl': '/videos/item-1/master.m3u8?MediaSourceId=src-1&PlaySessionId=ps-transcode',
              'MediaStreams': [
                {'Index': 0, 'Type': 'Video'},
              ],
            },
          ],
        });
      }
      return http.Response('{}', 404);
    }),
  );
  return (client: client, playbackInfo: playbackInfo);
}

PlaybackInitializationOptions _original({int? viewOffsetMs}) => PlaybackInitializationOptions(
  metadata: testMediaItem(
    id: 'item-1',
    backend: MediaBackend.jellyfin,
    kind: MediaKind.movie,
    serverId: 'srv-1',
    viewOffsetMs: viewOffsetMs,
  ),
  selectedMediaIndex: 0,
);

void main() {
  setUpAll(() => DeviceIdentityService.debugOverride(const DeviceIdentity(platform: 'Test')));
  tearDownAll(() => DeviceIdentityService.debugOverride(null));
  setUp(() {
    VexDeviceLimits.debugCurrent = _fire;
    VexForcedTranscode.debugReset();
  });
  tearDown(() => VexDeviceLimits.debugCurrent = null);

  test('Original uses the server transcode when the hardware cannot direct play', () async {
    final server = _server(directPlay: false);
    addTearDown(server.client.close);

    final result = await server.client.getPlaybackInitialization(_original(viewOffsetMs: 60000));

    expect(result.isTranscoding, isTrue);
    expect(result.playMethod, 'Transcode');
    expect(Uri.parse(result.videoUrl!).path, '/videos/item-1/master.m3u8');
    expect(server.playbackInfo, hasLength(2));
    final first = jsonDecode(server.playbackInfo.first.body) as Map<String, dynamic>;
    expect(first['MaxStreamingBitrate'], vexUnlimitedBitrate);
    expect((first['DeviceProfile'] as Map)['CodecProfiles'], isNotEmpty);
    expect(server.playbackInfo.last.url.queryParameters['StartTimeTicks'], '600000000');
  });

  test('Original keeps direct play when the hardware can decode it', () async {
    final server = _server(directPlay: true);
    addTearDown(server.client.close);

    final result = await server.client.getPlaybackInitialization(_original());

    expect(result.isTranscoding, isFalse);
    expect(result.playMethod, 'DirectPlay');
    expect(server.playbackInfo, hasLength(1));
  });

  test('a failed direct play forces a transcode-only negotiation', () async {
    VexForcedTranscode.mark('item-1');
    final server = _server(directPlay: false);
    addTearDown(server.client.close);

    final result = await server.client.getPlaybackInitialization(_original(viewOffsetMs: 1000));

    expect(result.isTranscoding, isTrue);
    final query = server.playbackInfo.single.url.queryParameters;
    expect(query['EnableDirectPlay'], 'false');
    expect(query['EnableDirectStream'], 'false');
    expect(query['StartTimeTicks'], '10000000');
  });
}
