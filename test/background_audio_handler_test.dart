import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/background_audio_handler.dart';
import 'package:dmusic_app/services/player_service.dart';
import 'package:flutter_test/flutter_test.dart';

Song song(String id) => Song(
  id: id,
  name: 'Track $id',
  artist: 'Artist',
  album: 'Album',
  source: 'test',
  durationSeconds: 120,
  coverUrl: 'https://example.com/$id.jpg',
);

class FakePlayer extends Fake implements PlayerService {
  final songs = StreamController<Song?>.broadcast(sync: true);
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final positions = StreamController<Duration>.broadcast(sync: true);
  final durations = StreamController<Duration>.broadcast(sync: true);
  final playlists = StreamController<List<Song>>.broadcast(sync: true);
  final modes = StreamController<PlayMode>.broadcast(sync: true);
  final transitions = StreamController<bool>.broadcast(sync: true);

  @override
  Song? currentSong = song('one');
  @override
  List<Song> playlist = [song('one'), song('two')];
  @override
  int currentIndex = 0;
  @override
  PlayerState playerState = PlayerState.paused;
  @override
  Duration currentPosition = const Duration(seconds: 17);
  @override
  Duration currentDuration = const Duration(seconds: 121);
  @override
  double playbackRate = 1.0;
  @override
  PlayMode playMode = PlayMode.listLoop;
  @override
  bool isTransitioning = false;
  @override
  bool isRestoredSession = false;
  int saves = 0;
  Completer<void>? pauseGate;
  Completer<void>? saveGate;
  Completer<void>? saveEntered;

  @override
  bool get isPlaying => playerState == PlayerState.playing;
  @override
  Stream<Song?> get currentSongStream => songs.stream;
  @override
  Stream<PlayerState> get stateStream => states.stream;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration> get durationStream => durations.stream;
  @override
  Stream<List<Song>> get playlistStream => playlists.stream;
  @override
  Stream<PlayMode> get playModeStream => modes.stream;
  @override
  Stream<bool> get transitioningStream => transitions.stream;

  @override
  Future<void> resume() async {
    isRestoredSession = false;
    playerState = PlayerState.playing;
    states.add(playerState);
  }

  @override
  Future<void> pause() async {
    await pauseGate?.future;
    playerState = PlayerState.paused;
    states.add(playerState);
  }

  @override
  Future<void> savePlaybackStateNow() async {
    saves++;
    saveEntered?.complete();
    await saveGate?.future;
  }

  @override
  Future<void> seek(Duration position) async {
    currentPosition = position;
    positions.add(position);
  }

  @override
  Future<void> setPlaybackRate(double rate) async => playbackRate = rate;

  @override
  void setPlayMode(PlayMode mode) {
    playMode = mode;
    modes.add(mode);
  }

  @override
  void playNext() {
    currentIndex = 1;
    currentSong = playlist[1];
    songs.add(currentSong);
  }

  @override
  void playPrev() {
    currentIndex = 0;
    currentSong = playlist[0];
    songs.add(currentSong);
  }

  Future<void> close() async {
    await Future.wait([
      songs.close(),
      states.close(),
      positions.close(),
      durations.close(),
      playlists.close(),
      modes.close(),
      transitions.close(),
    ]);
  }
}

void main() {
  late FakePlayer player;
  late DMusicAudioHandler handler;
  late List<bool> active;
  late int generation;
  Future<void> Function()? exit;
  Future<void> Function()? open;

  setUp(() {
    player = FakePlayer();
    active = [];
    generation = 1;
    exit = null;
    open = null;
    handler = DMusicAudioHandler(
      player: player,
      prepareForExit: () async {
        if (exit != null) return exit!();
        await player.pause();
        await player.savePlaybackStateNow();
      },
      sessionGeneration: () => generation,
      isCurrentSession: (value) => value == generation,
      setMediaSessionActive: (value) async => active.add(value),
      ensureSessionOpen: () async => open?.call(),
    );
  });

  tearDown(() async {
    await handler.dispose();
    await player.close();
  });

  test(
    'publishes actual metadata, queue, position and duration without UI',
    () {
      expect(handler.mediaItem.value?.id, 'test::one');
      expect(handler.mediaItem.value?.title, 'Track one');
      expect(handler.mediaItem.value?.duration, const Duration(seconds: 121));
      expect(handler.queue.value.map((item) => item.id), [
        'test::one',
        'test::two',
      ]);
      expect(
        handler.playbackState.value.updatePosition,
        const Duration(seconds: 17),
      );
      player.currentPosition = const Duration(seconds: 39);
      player.positions.add(player.currentPosition);
      expect(
        handler.playbackState.value.updatePosition,
        const Duration(seconds: 39),
      );
      player.currentDuration = const Duration(seconds: 132);
      player.durations.add(player.currentDuration);
      expect(handler.mediaItem.value?.duration, const Duration(seconds: 132));
    },
  );

  test(
    'routes media controls to the existing player and reports real state',
    () async {
      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);
      await handler.seek(const Duration(seconds: 51));
      expect(
        handler.playbackState.value.updatePosition,
        const Duration(seconds: 51),
      );
      await handler.setSpeed(1.25);
      expect(handler.playbackState.value.speed, 1.25);
      await handler.skipToNext();
      expect(handler.mediaItem.value?.id, 'test::two');
      expect(handler.playbackState.value.queueIndex, 1);
      await handler.skipToPrevious();
      expect(handler.playbackState.value.queueIndex, 0);
      await handler.pause();
      expect(handler.playbackState.value.playing, isFalse);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
    },
  );

  test('publishes repeat and shuffle modes from PlayerService', () async {
    await handler.setRepeatMode(AudioServiceRepeatMode.one);
    expect(handler.playbackState.value.repeatMode, AudioServiceRepeatMode.one);
    await handler.setShuffleMode(AudioServiceShuffleMode.all);
    expect(
      handler.playbackState.value.shuffleMode,
      AudioServiceShuffleMode.all,
    );
    await handler.setShuffleMode(AudioServiceShuffleMode.none);
    expect(
      handler.playbackState.value.shuffleMode,
      AudioServiceShuffleMode.none,
    );
  });

  test(
    'stop preserves song and checkpoint and allows subsequent play',
    () async {
      await handler.play();
      final current = player.currentSong;
      await handler.stop();
      expect(player.currentSong, same(current));
      expect(player.saves, 1);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(active.last, isFalse);
      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
      expect(active.last, isTrue);
    },
  );

  test('restored song without a loaded source remains idle', () {
    player.isRestoredSession = true;
    player.states.add(PlayerState.paused);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
    expect(handler.playbackState.value.playing, isFalse);
  });

  test(
    'task removal pauses, saves and publishes idle without clearing song',
    () async {
      await handler.play();
      await handler.onTaskRemoved();
      expect(player.currentSong?.id, 'one');
      expect(player.saves, 1);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(active.last, isFalse);
    },
  );

  test('late task removal cannot close a newly opened session', () async {
    final gate = Completer<void>();
    exit = () => gate.future;
    final removal = handler.onTaskRemoved();
    generation++;
    await handler.play();
    gate.complete();
    await removal;
    expect(handler.playbackState.value.playing, isTrue);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    expect(active.last, isTrue);
  });

  for (final taskRemoval in [false, true]) {
    for (final buffering in [false, true]) {
      test(
        'late ${taskRemoval ? 'task removal' : 'stop'} preserves direct ${buffering ? 'buffering' : 'playback'} in the same session',
        () async {
          await handler.play();
          player.saveEntered = Completer<void>();
          player.saveGate = Completer<void>();
          final stopping = taskRemoval
              ? handler.onTaskRemoved()
              : handler.stop();
          await player.saveEntered!.future;
          if (buffering) {
            player.isTransitioning = true;
            player.transitions.add(true);
          } else {
            await player.resume();
          }
          player.saveGate!.complete();
          await stopping;
          expect(handler.playbackState.value.playing, isTrue);
          expect(
            handler.playbackState.value.processingState,
            buffering
                ? AudioProcessingState.buffering
                : AudioProcessingState.ready,
          );
          expect(active.last, isTrue);
        },
      );
    }
  }

  test(
    'headless media play and skip reopen the native playback session',
    () async {
      var openings = 0;
      open = () async => openings++;
      await handler.play();
      expect(openings, 1);
      await handler.skipToNext();
      expect(openings, 2);
      await handler.skipToPrevious();
      expect(openings, 3);
    },
  );

  test(
    'pause supersedes a headless play waiting for native session reopen',
    () async {
      final gate = Completer<void>();
      open = () => gate.future;
      final playing = handler.play();
      await handler.pause();
      gate.complete();
      await playing;
      expect(player.isPlaying, isFalse);
      expect(handler.playbackState.value.playing, isFalse);
    },
  );

  test('dispose is idempotent and detaches player subscriptions', () async {
    await handler.dispose();
    await handler.dispose();
    expect(player.songs.hasListener, isFalse);
    expect(player.states.hasListener, isFalse);
    expect(player.positions.hasListener, isFalse);
    expect(player.durations.hasListener, isFalse);
    expect(player.playlists.hasListener, isFalse);
    expect(player.modes.hasListener, isFalse);
    expect(player.transitions.hasListener, isFalse);
  });
}
