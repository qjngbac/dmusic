import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/player_service.dart';
import 'package:dmusic_app/services/playback_cache_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';

import 'audio_fixtures.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late Directory directory;
  late PlayerService player;
  late MockStreamHandlerEventSink events;
  var nativePosition = 0;
  var rejectNextResume = false;
  var rejectPreparations = false;
  var rejectRollbackAfterResume = false;
  String? lastNativeUrl;
  String? heldRestoreUrl;
  Completer<void>? restoreEntered;
  Completer<void>? releaseRestore;
  Completer<void>? volumeEntered;
  Completer<void>? releaseVolume;
  Completer<void>? releaseEntered;
  Completer<void>? releaseNative;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('dmusic-player-test-');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.dmusic.app/widget'),
      (_) async => true,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (_) async => null,
    );
    messenger.setMockStreamHandler(
      const EventChannel('xyz.luan/audioplayers.global/events'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        calls.add(call);
        final arguments = call.arguments as Map;
        if (call.method == 'setVolume' && volumeEntered != null) {
          final entered = volumeEntered!;
          volumeEntered = null;
          entered.complete();
          await releaseVolume!.future;
        }
        if (call.method == 'release' && releaseEntered != null) {
          final entered = releaseEntered!;
          releaseEntered = null;
          entered.complete();
          await releaseNative!.future;
        }
        if (call.method == 'create') {
          final id = arguments['playerId'];
          messenger.setMockStreamHandler(
            EventChannel('xyz.luan/audioplayers/events/$id'),
            MockStreamHandler.inline(
              onListen: (_, sink) {
                events = sink;
              },
            ),
          );
        }
        if (call.method == 'setSourceUrl') {
          if (rejectPreparations) {
            // The channel fails before replacing the real native source.
            // An already queued prepared event must not prove adoption.
            events.success({'event': 'audio.onPrepared', 'value': true});
            throw PlatformException(code: 'prepare_failed');
          }
          if (heldRestoreUrl != null && arguments['url'] == heldRestoreUrl) {
            restoreEntered!.complete();
            await releaseRestore!.future;
          }
          lastNativeUrl = arguments['url'] as String;
          nativePosition = 0;
          events.success({'event': 'audio.onPrepared', 'value': true});
          events.success({'event': 'audio.onDuration', 'value': 180000});
        }
        if (call.method == 'getCurrentPosition') return nativePosition;
        if (call.method == 'getDuration') return 180000;
        if (call.method == 'resume' && rejectNextResume) {
          rejectNextResume = false;
          if (rejectRollbackAfterResume) rejectPreparations = true;
          throw PlatformException(code: 'resume_failed');
        }
        if (call.method == 'seek') {
          nativePosition = arguments['position'] as int;
          events.success({'event': 'audio.onSeekComplete'});
        }
        return null;
      },
    );
    player = PlayerService();
    await Future<void>.delayed(Duration.zero);
  });

  setUp(() async {
    await player.stop();
    player.clearPlaylist();
    nativePosition = 0;
    rejectNextResume = false;
    rejectPreparations = false;
    rejectRollbackAfterResume = false;
    heldRestoreUrl = null;
    restoreEntered = null;
    releaseRestore = null;
    volumeEntered = null;
    releaseVolume = null;
    releaseEntered = null;
    releaseNative = null;
    calls.clear();
  });

  tearDownAll(() async {
    await Future.sync(player.dispose);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await directory.delete(recursive: true);
  });

  Song online(String id) => Song(
    id: id,
    name: id,
    artist: 'artist',
    album: '',
    source: 'QQ音乐',
    quality: '320k 极高',
    lyric: '[00:00.00]test',
    audioUrl: 'https://audio.example/original.mp3',
    audioUrlQuality: 'auto',
    audioUrlTimestamp: DateTime.now().millisecondsSinceEpoch,
  );

  MockClient client({bool fail = false, Completer<http.Response>? delayed}) =>
      MockClient((request) async {
        if (fail && request.url.host != 'audio.example') {
          return http.Response('{}', 404);
        }
        if (request.url.host == 'audio.example') {
          final bytes = request.url.path.endsWith('.flac')
              ? flacFixture(payloadSize: 4096)
              : mp3Fixture(
                  bitrate: request.url.path.contains('128') ? 128 : request.url.path.contains('256') ? 256 : 320,
                );
          return http.Response.bytes(
            bytes,
            200,
            headers: {'content-type': 'audio/mpeg'},
          );
        }
        if (request.url.path == '/kgqq/qq.php') {
          if (delayed != null) return delayed.future;
          final level = request.url.queryParameters['level'];
          final url = level == 'lossless'
              ? 'https://audio.example/stream.flac'
              : 'https://audio.example/${level ?? '320'}.mp3';
          return http.Response(
            jsonEncode({
              'data': {'url': url},
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

  Future<Song> local(String id, String source, int seconds) async {
    final file = File('${directory.path}/$source-$id.wav');
    await file.writeAsBytes(
      wavFixture(seconds: seconds, sampleRate: 44100, channels: 2),
    );
    return Song(
      id: id,
      name: id,
      artist: 'artist',
      album: '',
      source: source,
      localFilePath: file.path,
      lyric: '[00:00.00]test',
    );
  }

  test(
    'plays a valid short local WAV instead of rejecting it by file size',
    () async {
      await player.playSong(await local('short', '本地', 1));
      expect(calls.where((call) => call.method == 'setSourceUrl'), isNotEmpty);
      expect(player.currentSong?.quality, contains('PCM'));
      expect(player.isPlaying, true);
    },
  );

  test('same ID from two sources remains two distinct queue entries', () async {
    await player.playSong(await local('same-id', '本地', 10));
    await player.playSong(await local('same-id', '本地扫描', 10));
    expect(player.playlist.map((song) => song.key), [
      '本地::same-id',
      '本地扫描::same-id',
    ]);
    expect(player.currentIndex, 1);
  });

  test('a legacy downloaded MP4 audio track plays locally without a network lookup', () async {
    final file = await File('${directory.path}/legacy-audio.mp3')
        .writeAsBytes(mp4Fixture(video: true));
    var requests = 0;
    await http.runWithClient(() => player.playSong(Song(
      id: 'legacy-mp4', name: 'Legacy recording', artist: 'artist', album: '',
      source: '网易云', localFilePath: file.path, durationSeconds: 10,
      lyric: '[00:00.00]test',
    )), () => MockClient((_) async {
      requests++;
      return http.Response('{}', 503);
    }));
    expect(requests, 0);
    expect(lastNativeUrl, file.path);
    expect(player.currentSong?.quality, contains('MP4'));
    expect(player.isPlaying, true);
  });

  test(
    'online resolution cannot mutate the catalog song or force 128k',
    () async {
      final song = online('catalog');
      await http.runWithClient(() => player.playSong(song), () => client());
      expect(identical(player.currentSong, song), false);
      expect(song.audioUrl, 'https://audio.example/original.mp3');
      expect(song.quality, '320k 极高');
      expect(player.currentSong?.audioUrlQuality, '256k');
      expect(player.currentSong?.quality, contains('256'));
    },
  );

  test('complete playback cache starts offline without looking downloaded', () async {
    final song = online('offline-cache');
    final source = await http.runWithClient(
      () => PlaybackCacheService.instance.createSource(song, 'https://audio.example/256.mp3'),
      () => client(),
    );
    await HttpOverrides.runWithHttpOverrides(() async {
      final transport = IOClient();
      try { await transport.get(source.uri); } finally { transport.close(); }
    }, _RealHttp());
    await source.release();
    var networkRequests = 0;
    await http.runWithClient(() async {
      await player.playSong(song);
      nativePosition = 170000;
      await player.positionStream.firstWhere((pos) => pos.inSeconds >= 170)
          .timeout(const Duration(seconds: 5));
    }, () => MockClient((request) async {
      networkRequests++;
      return http.Response('{}', 503);
    }));
    expect(networkRequests, 0);
    expect(player.isPlaying, true);
    expect(player.currentSong?.quality, contains('256'));
    expect(player.currentSong?.isDownloaded, false);
    expect((calls.lastWhere((call) => call.method == 'setSourceUrl').arguments as Map)['isLocal'], true);
  });

  test('fresh selection of 256k menu label resolves and preserves requested tier', () async {
    await http.runWithClient(() async {
      await player.playSong(online('menu-256'));
      await player.switchQuality(player.currentSong!, '128k 标准');
      await player.switchQuality(player.currentSong!, '256k 高品');
      expect(player.currentSong?.audioUrlQuality, '256k');
      expect(player.currentSong?.quality, contains('256'));
    }, () => client());
  });

  test('native playback stream becomes an offline cache and rollback keeps its file pinned', () async {
    final song = online('native-stream-cache');
    var audioRequests = 0;
    await http.runWithClient(() async {
      await player.playSong(song);
      final beforeNativeGet = audioRequests;
      final proxy = Uri.parse(lastNativeUrl!);
      expect(proxy.host, '127.0.0.1');
      await HttpOverrides.runWithHttpOverrides(() async {
        final transport = IOClient();
        try {
          final response = await transport.get(proxy);
          expect(response.statusCode, 200);
          expect(response.bodyBytes, mp3Fixture(bitrate: 256));
        } finally { transport.close(); }
      }, _RealHttp());
      await player.stop();
      expect(audioRequests, beforeNativeGet + 1);
    }, () => MockClient((request) {
      if (request.url.host == 'audio.example') audioRequests++;
      return client().get(request.url, headers: request.headers);
    }));

    var offlineRequests = 0;
    await http.runWithClient(() => player.playSong(song), () => MockClient((request) async {
      offlineRequests++;
      return http.Response('{}', 503);
    }));
    expect(offlineRequests, 0);
    final cachedPath = lastNativeUrl!;
    expect(player.currentSong!.localFilePath, isNull);
    nativePosition = 43000;
    rejectNextResume = true;
    await http.runWithClient(() async {
      await expectLater(player.switchQuality(player.currentSong!, '128k 标准'), throwsStateError);
    }, () => client());
    expect(lastNativeUrl, cachedPath);
    expect(nativePosition, 43000);
    expect(player.isPlaying, true);
    final hit = await PlaybackCacheService.instance.find(song);
    expect(hit, isNotNull);
    final file = hit!.file;
    await hit.release();
    await PlaybackCacheService.instance.invalidate(hit.key);
    expect(await file.exists(), true);
    await player.stop();
    expect(await file.exists(), false);
  });

  test(
    'switching a paused song keeps it paused and preserves its position',
    () async {
      await http.runWithClient(() async {
        await player.playSong(online('paused'));
        await player.pause();
        nativePosition = 42000;
        calls.clear();
        await player.switchQuality(player.currentSong!, '128k 标准');
        expect(player.isPlaying, false);
        expect(calls.where((call) => call.method == 'resume'), isEmpty);
        expect(nativePosition, 42000);
        expect(player.currentSong?.audioUrlQuality, '128k');
      }, () => client());
    },
  );

  test(
    'unavailable quality throws and leaves the previous song and stream intact',
    () async {
      await http.runWithClient(
        () => player.playSong(online('rollback')),
        () => client(),
      );
      final before = player.currentSong;
      calls.clear();
      await http.runWithClient(() async {
        await expectLater(
          player.switchQuality(before!, 'FLAC 无损'),
          throwsStateError,
        );
      }, () => client(fail: true));
      expect(identical(player.currentSong, before), true);
      expect(calls.where((call) => call.method == 'setSourceUrl'), isEmpty);
      expect(before!.quality, contains('256'));
    },
  );

  test('native resume failure restores the previous playable URL', () async {
    await http.runWithClient(
      () => player.playSong(online('native-failure')),
      () => client(),
    );
    final before = player.currentSong;
    final previousNativeUrl = lastNativeUrl;
    nativePosition = 43000;
    rejectNextResume = true;
    await http.runWithClient(() async {
      await expectLater(
        player.switchQuality(before!, '128k 标准'),
        throwsStateError,
      );
    }, () => client());
    expect(identical(player.currentSong, before), true);
    expect(player.currentSong?.audioUrl, before?.audioUrl);
    expect(nativePosition, 43000);
    final sourceCalls = calls.where((call) => call.method == 'setSourceUrl');
    expect((sourceCalls.last.arguments as Map)['url'], previousNativeUrl);
  });

  test('failed native prepare and rollback keep the previous proxy alive until release', () async {
    await http.runWithClient(() async {
      await player.playSong(online('failed-prepare'));
      final previousProxy = Uri.parse(lastNativeUrl!);
      rejectPreparations = true;
      await expectLater(player.switchQuality(player.currentSong!, '128k 标准'), throwsStateError);
      expect(lastNativeUrl, previousProxy.toString());
      final attempts = calls.where((call) => call.method == 'setSourceUrl').toList();
      final failedProxy = Uri.parse((attempts[attempts.length - 2].arguments as Map)['url'] as String);
      await HttpOverrides.runWithHttpOverrides(() async {
        final transport = IOClient();
        try {
          expect((await transport.get(previousProxy)).statusCode, 200);
          expect((await transport.get(failedProxy)).statusCode, 200);
          await player.stop();
          expect((await transport.get(previousProxy)).statusCode, 404);
          expect((await transport.get(failedProxy)).statusCode, 404);
        } finally { transport.close(); }
      }, _RealHttp());
    }, () => client());
  });

  test('accepted new source with failed resume and failed rollback retains both inputs', () async {
    await http.runWithClient(() async {
      await player.playSong(online('failed-rollback-after-prepare'));
      final previousProxy = Uri.parse(lastNativeUrl!);
      rejectNextResume = true;
      rejectRollbackAfterResume = true;
      await expectLater(player.switchQuality(player.currentSong!, '128k 标准'), throwsStateError);
      final newProxy = Uri.parse(lastNativeUrl!);
      expect(newProxy, isNot(previousProxy));
      await HttpOverrides.runWithHttpOverrides(() async {
        final transport = IOClient();
        try {
          expect((await transport.get(previousProxy)).statusCode, 200);
          expect((await transport.get(newProxy)).statusCode, 200);
          await player.stop();
          expect((await transport.get(previousProxy)).statusCode, 404);
          expect((await transport.get(newProxy)).statusCode, 404);
        } finally { transport.close(); }
      }, _RealHttp());
    }, () => client());
  });

  test(
    'older quality request cannot overwrite a newer choice for the same song',
    () async {
      await http.runWithClient(
        () => player.playSong(online('same-song')),
        () => client(),
      );
      final oldStarted = Completer<void>();
      final oldResponse = Completer<http.Response>();
      await http.runWithClient(
        () async {
          final song = player.currentSong!;
          final older = player.switchQuality(song, '128k 标准');
          await oldStarted.future.timeout(const Duration(seconds: 5));
          await player.switchQuality(song, '320k 极高');
          oldResponse.complete(
            http.Response(
              jsonEncode({
                'data': {'url': 'https://audio.example/128.mp3'},
              }),
              200,
            ),
          );
          await expectLater(older, throwsStateError);
          expect(player.currentSong?.audioUrlQuality, '320k');
          expect(player.currentSong?.audioUrl, 'https://audio.example/320.mp3');
          expect(
            (calls.lastWhere((call) => call.method == 'setSourceUrl').arguments
                as Map)['url'],
            startsWith('http://127.0.0.1:'),
          );
        },
        () => MockClient((request) {
          if (request.url.path == '/kgqq/qq.php' &&
              request.url.queryParameters['level'] == '128') {
            oldStarted.complete();
            return oldResponse.future;
          }
          return client().get(request.url, headers: request.headers);
        }),
      );
    },
  );

  test('user pause cancels a pending quality switch', () async {
    await http.runWithClient(
      () => player.playSong(online('pause-switch')),
      () => client(),
    );
    final oldSong = player.currentSong;
    final started = Completer<void>();
    final delayed = Completer<http.Response>();
    await http.runWithClient(
      () async {
        final switching = player.switchQuality(oldSong!, '128k 标准');
        await started.future.timeout(const Duration(seconds: 5));
        await player.pause();
        delayed.complete(
          http.Response(
            jsonEncode({
              'data': {'url': 'https://audio.example/128.mp3'},
            }),
            200,
          ),
        );
        await expectLater(switching, throwsStateError);
        expect(player.isPlaying, false);
        expect(identical(player.currentSong, oldSong), true);
      },
      () => MockClient((request) {
        if (request.url.path == '/kgqq/qq.php' &&
            request.url.queryParameters['level'] == '128') {
          started.complete();
          return delayed.future;
        }
        return client().get(request.url, headers: request.headers);
      }),
    );
  });

  test('an older pause cannot pause a newly selected song', () async {
    await http.runWithClient(() async {
      await player.playSong(online('before-stale-pause'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final entered = volumeEntered = Completer<void>();
      releaseVolume = Completer<void>();
      final pausing = player.pause();
      await entered.future.timeout(const Duration(seconds: 5));
      await player.playSong(await local('after-stale-pause', '本地', 10));
      releaseVolume!.complete();
      await pausing;
      expect(player.currentSong?.name, 'after-stale-pause');
      expect(player.isPlaying, true);
    }, () => client());
  });

  test('an older stop cannot clear a new song selected during native release', () async {
    await http.runWithClient(() async {
      await player.playSong(online('before-stale-stop'));
      final entered = releaseEntered = Completer<void>();
      releaseNative = Completer<void>();
      final stopping = player.stop();
      await entered.future.timeout(const Duration(seconds: 5));
      final next = online('after-stale-stop');
      final changed = player.currentSongStream.firstWhere((s) => s?.key == next.key);
      final replacing = player.playSong(next);
      await changed;
      releaseNative!.complete();
      await stopping;
      await replacing;
      expect(player.currentSong?.key, next.key);
      expect(player.isPlaying, true);
      final proxy = Uri.parse(lastNativeUrl!);
      await HttpOverrides.runWithHttpOverrides(() async {
        final transport = IOClient();
        try {
          expect((await transport.get(proxy)).statusCode, 200);
          await player.stop();
          expect((await transport.get(proxy)).statusCode, 404);
        } finally { transport.close(); }
      }, _RealHttp());
    }, () => client());
  });

  test('rollback cannot seek or resume a newly selected song', () async {
    await http.runWithClient(
      () => player.playSong(online('rollback-race')),
      () => client(),
    );
    heldRestoreUrl = lastNativeUrl;
    restoreEntered = Completer<void>();
    releaseRestore = Completer<void>();
    nativePosition = 43000;
    rejectNextResume = true;
    await http.runWithClient(() async {
      final switching = player.switchQuality(player.currentSong!, '128k 标准');
      await restoreEntered!.future.timeout(const Duration(seconds: 5));
      final next = await local('new-during-rollback', '本地', 10);
      final changed = player.currentSongStream.firstWhere(
        (s) => s?.key == next.key,
      );
      final replacing = player.playSong(next);
      await changed;
      releaseRestore!.complete();
      await expectLater(switching, throwsStateError);
      await replacing;
      expect(player.currentSong?.name, 'new-during-rollback');
      expect(lastNativeUrl, next.localFilePath);
      expect(nativePosition, 0);
    }, () => client());
  });

  test(
    'a delayed quality switch cannot replace a newly selected song',
    () async {
      await http.runWithClient(
        () => player.playSong(online('cancelled')),
        () => client(),
      );
      final delayed = Completer<http.Response>();
      await http.runWithClient(() async {
        final switching = player.switchQuality(player.currentSong!, '128k 标准');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await player.playSong(await local('new', '本地', 10));
        delayed.complete(
          http.Response(
            jsonEncode({
              'data': {'url': 'https://audio.example/128.mp3'},
            }),
            200,
          ),
        );
        await expectLater(switching, throwsStateError);
        expect(player.currentSong?.name, 'new');
        expect(
          (calls.lastWhere((call) => call.method == 'setSourceUrl').arguments
              as Map)['isLocal'],
          true,
        );
      }, () => client(delayed: delayed));
    },
  );

  test('a new song cannot inherit the restored song pending seek', () async {
    final restored = await local('restored', '本地', 10);
    await File('${directory.path}/dmusic_playback_state.json').writeAsString(
      jsonEncode({
        'song': restored.toJson(),
        'playlist': [restored.toJson()],
        'positionMs': 65000,
        'durationMs': 180000,
      }),
    );
    await player.restorePlaybackState();
    calls.clear();
    await player.playSong(await local('next', '本地', 10));
    expect(calls.where((call) => call.method == 'seek'), isEmpty);
    expect(player.currentPosition, Duration.zero);
  });

  test(
    'a stale watchdog response cannot restart a newly selected song',
    () async {
      final requested = Completer<void>();
      final delayed = Completer<http.Response>();
      await http.runWithClient(
        () async {
          await player.playSong(
            online('watchdog').copyWith(
              audioUrl: 'https://audio.example/stream.flac',
              isLossless: true,
              quality: 'FLAC 无损',
              audioUrlQuality: 'flac',
            ),
          );
          await requested.future.timeout(const Duration(seconds: 9));
          await player.playSong(await local('watchdog-new', '本地', 10));
          delayed.complete(
            http.Response(
              jsonEncode({
                'data': {'url': 'https://audio.example/stream.flac'},
              }),
              200,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(player.currentSong?.name, 'watchdog-new');
          expect(
            (calls.lastWhere((call) => call.method == 'setSourceUrl').arguments
                as Map)['isLocal'],
            true,
          );
        },
        () => MockClient((request) {
          if (request.url.path == '/kgqq/qq.php' &&
              request.url.queryParameters['level'] == 'lossless') {
            if (!requested.isCompleted) requested.complete();
            return delayed.future;
          }
          return client().get(request.url, headers: request.headers);
        }),
      );
    },
  );

  test(
    'unsupported EQ changes report an error without publishing fictitious gains',
    () async {
      final error = player.errorStream.first;
      player.setEqBand(0, 6);
      expect(player.eqBands.first, 0);
      expect(await error, contains('尚不支持'));
    },
  );
}
