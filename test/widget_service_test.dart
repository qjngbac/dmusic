import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/main.dart';
import 'package:dmusic_app/services/player_service.dart';
import 'package:dmusic_app/services/database_service.dart';
import 'package:dmusic_app/services/widget_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'audio_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.dmusic.app/widget');
  final updates = <Map<String, dynamic>>[];
  final nativeCalls = <MethodCall>[];
  final playerCalls = <String>[];
  Completer<void>? pauseEntered;
  Completer<void>? releasePause;
  Completer<void>? closeEntered;
  Completer<void>? releaseClose;
  Completer<void>? activeEntered;
  Completer<void>? releaseActive;
  Completer<void>? volumeEntered;
  Completer<void>? releaseVolume;
  Completer<Map<String, dynamic>>? connection;
  late Directory directory;
  late MockStreamHandlerEventSink events;
  var initialized = false;
  var generation = 7;
  var nativePosition = 0;

  Future<void> native(String method, [Map<String, dynamic>? arguments]) async {
    final completed = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      (_) => completed.complete(),
    );
    await completed.future;
  }

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('dmusic-widget-test-');
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => directory.path,
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
        playerCalls.add(call.method);
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockStreamHandler(
            EventChannel('xyz.luan/audioplayers/events/$id'),
            MockStreamHandler.inline(onListen: (_, sink) => events = sink),
          );
        }
        if (call.method == 'setSourceUrl') {
          nativePosition = 0;
          events.success({'event': 'audio.onPrepared', 'value': true});
        }
        if (call.method == 'getCurrentPosition') return nativePosition;
        if (call.method == 'getDuration') return 120000;
        if (call.method == 'seek') {
          nativePosition = (call.arguments as Map)['position'] as int;
          events.success({'event': 'audio.onSeekComplete'});
        }
        if (call.method == 'setVolume' && releaseVolume != null) {
          final blocked = releaseVolume!;
          releaseVolume = null;
          volumeEntered!.complete();
          await blocked.future;
        }
        if (call.method == 'pause' && releasePause != null) {
          if (!pauseEntered!.isCompleted) pauseEntered!.complete();
          await releasePause!.future;
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      if (call.method == 'connectPlaybackSession') {
        return connection?.future ?? Future.value({'generation': generation});
      }
      if (call.method == 'openPlaybackSession') {
        return {'generation': ++generation};
      }
      if (call.method == 'beginPlaybackExit' && releaseClose != null) {
        closeEntered!.complete();
        await releaseClose!.future;
      }
      if (call.method == 'mediaSessionActive' && releaseActive != null) {
        if (!activeEntered!.isCompleted) activeEntered!.complete();
        await releaseActive!.future;
      }
      if (call.method == 'updateWidget') {
        updates.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      return null;
    });
    PlayerService();
    await Future<void>.delayed(Duration.zero);
  });

  setUp(() async {
    if (initialized) {
      await native('onPlaybackSessionOpened', {'generation': ++generation});
    }
    updates.clear();
    nativeCalls.clear();
    playerCalls.clear();
    pauseEntered = null;
    releasePause = null;
    closeEntered = null;
    releaseClose = null;
    activeEntered = null;
    releaseActive = null;
    volumeEntered = null;
    releaseVolume = null;
    WidgetService().registerPlaybackStop(() async {});
  });

  tearDownAll(() async {
    final database = DatabaseService();
    await database.saveSearchPreferences(database.searchPreferences);
    await PlayerService().savePlaybackStateNow();
    await PlayerService().dispose();
    await directory.delete(recursive: true);
  });

  Song song(String id) => Song(
    id: id,
    name: id,
    artist: 'artist',
    album: 'album',
    source: 'test',
    coverUrl: 'https://covers.example/$id.jpg',
    durationSeconds: 120,
  );

  Future<void> playLocal(String id) async {
    final file = File('${directory.path}/$id.wav');
    await file.writeAsBytes(wavFixture(seconds: 1));
    await PlayerService().playSong(
      Song(
        id: id,
        name: id,
        artist: 'artist',
        album: 'album',
        source: '本地',
        localFilePath: file.path,
        lyric: '[00:00.00]test',
      ),
    );
    events.success({'event': 'audio.onDuration', 'value': 120000});
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'awaits native handshake and explicitly reopens a closed startup session',
    () async {
      connection = Completer<Map<String, dynamic>>();
      final service = WidgetService();
      await service.setMediaSessionActive(true);
      expect(nativeCalls, isEmpty);
      final result = service.init();
      await Future<void>.delayed(Duration.zero);
      expect(
        nativeCalls.map((call) => call.method),
        contains('connectPlaybackSession'),
      );
      expect(updates, isEmpty);
      expect(
        nativeCalls.any((call) => call.method == 'mediaSessionActive'),
        isFalse,
      );
      expect(result, isA<Future<void>>());
      connection!.complete({'generation': 7, 'closed': true});
      await result;
      initialized = true;
      connection = null;
      expect(
        nativeCalls.map((call) => call.method),
        contains('beginPlaybackExit'),
      );
      expect(
        nativeCalls.map((call) => call.method),
        contains('stopPlaybackService'),
      );
      expect(service.sessionGeneration, 7);
      expect(service.isCurrentSession(7), isTrue);
      expect(service.isCurrentSession(6), isFalse);
      updates.clear();
      service.syncWidget(song: song('closed-startup'));
      await Future<void>.delayed(Duration.zero);
      expect(updates, isEmpty);

      await service.ensurePlaybackSessionOpen();
      await Future<void>.delayed(Duration.zero);

      expect(service.sessionGeneration, 8);
      expect(updates, isNotEmpty);
      expect(updates.every((update) => update['generation'] == 8), isTrue);
      expect(PlayerService().isPlaying, isFalse);
    },
  );

  test(
    'publishes song state while its cover request is still pending',
    () async {
      final requested = Completer<void>();
      final cover = Completer<http.Response>();
      await http.runWithClient(
        () async {
          WidgetService().syncWidget(song: song('immediate'));
          await requested.future;
          try {
            expect(updates.last['title'], 'immediate');
            expect(updates.last['coverPath'], isNull);
            expect(updates.last['generation'], generation);
          } finally {
            cover.complete(http.Response.bytes([1, 2, 3], 200));
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        },
        () => MockClient((_) {
          requested.complete();
          return cover.future;
        }),
      );
    },
  );

  test('late cover for an old song cannot replace the latest song', () async {
    final requestedA = Completer<void>();
    final requestedB = Completer<void>();
    final coverA = Completer<http.Response>();
    final coverB = Completer<http.Response>();
    await http.runWithClient(
      () async {
        WidgetService().syncWidget(song: song('A'));
        await requestedA.future;
        WidgetService().syncWidget(song: song('B'));
        await requestedB.future;
        coverB.complete(http.Response.bytes([4, 5, 6], 200));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(updates.last['title'], 'B');
        expect(updates.last['coverPath'], isNotNull);
        coverA.complete(http.Response.bytes([1, 2, 3], 200));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(updates.last['title'], 'B');
      },
      () => MockClient((request) {
        if (request.url.path == '/A.jpg') {
          requestedA.complete();
          return coverA.future;
        }
        requestedB.complete();
        return coverB.future;
      }),
    );
  });

  test(
    'exit closes native epoch before pause and preserves the saved song',
    () async {
      await playLocal('dismissed');
      final service = WidgetService();
      updates.clear();
      nativeCalls.clear();
      pauseEntered = Completer<void>();
      releasePause = Completer<void>();
      final first = service.prepareForExit();
      final repeated = service.prepareForExit();
      expect(identical(first, repeated), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(nativeCalls.first.method, 'beginPlaybackExit');
      expect(nativeCalls.first.arguments, {'generation': generation});
      await pauseEntered!.future;
      service.syncWidget(song: song('ignored'));
      expect(updates, isEmpty);
      releasePause!.complete();
      await first;
      expect(updates.single['isPlaying'], isFalse);
      expect(updates.single['generation'], generation);
      final saved =
          jsonDecode(
                await File(
                  '${directory.path}/dmusic_playback_state.json',
                ).readAsString(),
              )
              as Map;
      expect((saved['song'] as Map)['id'], 'dismissed');
      expect(PlayerService().currentSong?.id, 'dismissed');
      expect(
        nativeCalls.any((call) => call.method == 'widgetHeartbeat'),
        isFalse,
      );
    },
  );

  test(
    'reopening invalidates old exit and cover without automatically playing',
    () async {
      await playLocal('reopen');
      final requested = Completer<void>();
      final cover = Completer<http.Response>();
      await http.runWithClient(
        () async {
          final service = WidgetService();
          service.syncWidget(song: song('old-epoch-cover'));
          await requested.future;
          pauseEntered = Completer<void>();
          releasePause = Completer<void>();
          final oldExit = service.prepareForExit();
          await pauseEntered!.future;
          updates.clear();
          playerCalls.clear();
          await native('onPlaybackSessionOpened', {'generation': ++generation});
          expect(updates.last['generation'], generation);
          releasePause!.complete();
          await oldExit;
          cover.complete(http.Response.bytes([1, 2, 3], 200));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(
            updates.every((update) => update['generation'] == generation),
            isTrue,
          );
          expect(
            updates.every((update) => update['title'] == 'reopen'),
            isTrue,
          );
          expect(PlayerService().isPlaying, isFalse);
          expect(playerCalls, isNot(contains('resume')));
          service.syncWidget(song: song('new-epoch'));
          await Future<void>.delayed(Duration.zero);
          expect(updates.last['title'], 'new-epoch');
          expect(updates.last['generation'], generation);
          // The old Future completing must not become the new epoch's exit latch.
          releasePause = null;
          final nextExit = service.prepareForExit();
          expect(identical(nextExit, oldExit), isFalse);
          await nextExit;
        },
        () => MockClient((_) {
          if (!requested.isCompleted) requested.complete();
          return cover.future;
        }),
      );
    },
  );

  test('reopen while native exit is pending prevents the old pause', () async {
    await playLocal('pending-exit');
    closeEntered = Completer<void>();
    releaseClose = Completer<void>();
    final exiting = WidgetService().prepareForExit();
    await closeEntered!.future;
    await native('onPlaybackSessionOpened', {'generation': ++generation});
    playerCalls.clear();
    releaseClose!.complete();
    await exiting;
    expect(playerCalls, isNot(contains('pause')));
    expect(PlayerService().isPlaying, isTrue);
  });

  test(
    'native activity transitions are ordered and old epochs are dropped',
    () async {
      final service = WidgetService();
      activeEntered = Completer<void>();
      releaseActive = Completer<void>();
      final stopping = service.setMediaSessionActive(false);
      await activeEntered!.future;
      final playing = service.setMediaSessionActive(true);
      await Future<void>.delayed(Duration.zero);
      final pendingCount = nativeCalls
          .where((call) => call.method == 'mediaSessionActive')
          .length;
      await native('onPlaybackSessionOpened', {'generation': ++generation});
      releaseActive!.complete();
      await stopping;
      await playing;
      await Future<void>.delayed(Duration.zero);
      expect(pendingCount, 1);
      final transitions = nativeCalls
          .where((call) => call.method == 'mediaSessionActive')
          .map((call) => call.arguments)
          .toList();
      expect(transitions, [
        {'active': false, 'generation': generation - 1},
        {'active': true, 'generation': generation},
      ]);
    },
  );

  test(
    'new playback supersedes a dismissed session while its pause is fading',
    () async {
      await playLocal('fade-reopen');
      volumeEntered = Completer<void>();
      final blocked = releaseVolume = Completer<void>();
      final exiting = WidgetService().prepareForExit();
      await volumeEntered!.future;
      await native('onPlaybackSessionOpened', {'generation': ++generation});
      await native('onWidgetAction', {'action': 'com.dmusic.app.ACTION_PLAY'});
      playerCalls.clear();
      blocked.complete();
      await exiting;
      expect(playerCalls, isNot(contains('pause')));
      expect(PlayerService().isPlaying, isTrue);
      expect(updates.last['isPlaying'], isTrue);
    },
  );

  test(
    'headless media controls can explicitly reopen a dismissed session',
    () async {
      await playLocal('media-reopen');
      final service = WidgetService();
      await service.prepareForExit();
      final previous = generation;
      await service.ensurePlaybackSessionOpen();
      expect(service.sessionGeneration, previous + 1);
      expect(PlayerService().isPlaying, isFalse);
      await native('onWidgetAction', {'action': 'com.dmusic.app.ACTION_PLAY'});
      expect(PlayerService().isPlaying, isTrue);
    },
  );

  test(
    'activity detach checkpoints without closing or pausing service playback',
    () async {
      await playLocal('activity-detach');
      nativeCalls.clear();
      playerCalls.clear();
      final observer =
          const MainScreen().createState() as WidgetsBindingObserver;
      observer.didChangeAppLifecycleState(AppLifecycleState.detached);
      await PlayerService().savePlaybackStateNow();
      expect(
        nativeCalls.any((call) => call.method == 'beginPlaybackExit'),
        isFalse,
      );
      expect(playerCalls, isNot(contains('pause')));
      expect(PlayerService().isPlaying, isTrue);
    },
  );

  test(
    'stop awaits audio handler before disconnecting native observer and stays reusable',
    () async {
      final service = WidgetService();
      final stopped = Completer<void>();
      final entered = Completer<void>();
      service.registerPlaybackStop(() async {
        entered.complete();
        await stopped.future;
      });
      final stopping = service.stopPlaybackService();
      await entered.future;
      expect(
        nativeCalls.any((call) => call.method == 'stopPlaybackService'),
        isFalse,
      );
      stopped.complete();
      await stopping;
      expect(nativeCalls.last.method, 'stopPlaybackService');
      expect(nativeCalls.last.arguments, {'generation': generation});
      updates.clear();
      service.syncWidget(song: song('after-stop'));
      await Future<void>.delayed(Duration.zero);
      expect(updates.last['title'], 'after-stop');
      service.registerPlaybackStop(() async {});
    },
  );

  test(
    'native widget actions run without an attached UI and resume after reopen',
    () async {
      await playLocal('headless');
      await PlayerService().pause();
      playerCalls.clear();
      await native('onWidgetAction', {'action': 'com.dmusic.app.ACTION_PLAY'});
      expect(playerCalls, contains('resume'));
      await WidgetService().prepareForExit();
      playerCalls.clear();
      await native('onWidgetAction', {
        'action': 'com.dmusic.app.ACTION_SEEK:1500',
      });
      expect(playerCalls, isNot(contains('seek')));
      await native('onPlaybackSessionOpened', {'generation': ++generation});
      await native('onWidgetAction', {
        'action': 'com.dmusic.app.ACTION_SEEK:1500',
      });
      expect(playerCalls, contains('seek'));
      expect(
        PlayerService().currentPosition,
        const Duration(milliseconds: 1500),
      );
    },
  );

  test(
    'native dismissal pauses and saves before stopping the audio service',
    () async {
      await playLocal('native-dismissal');
      var stops = 0;
      WidgetService().registerPlaybackStop(() async {
        expect(PlayerService().isPlaying, isFalse);
        stops++;
      });
      nativeCalls.clear();

      await native('onTaskDismissed', {'generation': generation});

      expect(stops, 1);
      expect(PlayerService().isPlaying, isFalse);
      expect(PlayerService().currentSong?.id, 'native-dismissal');
      expect(nativeCalls.first.method, 'beginPlaybackExit');
      expect(nativeCalls.last.method, 'stopPlaybackService');
    },
  );

  test('stale native dismissal cannot stop the current session', () async {
    await playLocal('stale-dismissal');
    var stops = 0;
    WidgetService().registerPlaybackStop(() async {
      stops++;
    });

    await native('onTaskDismissed', {'generation': generation - 1});

    expect(stops, 0);
    expect(PlayerService().isPlaying, isTrue);
  });

  test(
    'reopening during native dismissal prevents its late service stop',
    () async {
      await playLocal('dismissal-reopen');
      var stops = 0;
      WidgetService().registerPlaybackStop(() async {
        stops++;
      });
      pauseEntered = Completer<void>();
      releasePause = Completer<void>();
      final dismissed = native('onTaskDismissed', {'generation': generation});
      await pauseEntered!.future;

      await native('onPlaybackSessionOpened', {'generation': ++generation});
      releasePause!.complete();
      await dismissed;

      expect(stops, 0);
      expect(WidgetService().sessionGeneration, generation);
    },
  );

  test('an old native widget action cannot pause a reopened session', () async {
    await playLocal('stale-widget-action');
    playerCalls.clear();
    await native('onWidgetAction', {
      'action': 'com.dmusic.app.ACTION_PAUSE',
      'generation': generation - 1,
    });
    expect(PlayerService().isPlaying, isTrue);
    expect(playerCalls, isNot(contains('pause')));
  });
}
