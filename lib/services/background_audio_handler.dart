import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';

import '../models/song.dart';
import 'player_service.dart';
import 'widget_service.dart';

Future<DMusicAudioHandler> initializeBackgroundAudio() async {
  final handler = await AudioService.init<DMusicAudioHandler>(
    builder: DMusicAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'dmusic_playback_channel',
      androidNotificationChannelName: 'DMusic 音乐后台播放',
      androidNotificationIcon: 'drawable/ic_notification',
      androidNotificationOngoing: true,
      androidResumeOnClick: false,
      androidStopForegroundOnPause: true,
    ),
  );
  await handler._sessionActivation;
  WidgetService().registerPlaybackStop(handler.stop);
  return handler;
}

class DMusicAudioHandler extends BaseAudioHandler {
  DMusicAudioHandler({
    PlayerService? player,
    Future<void> Function()? prepareForExit,
    int Function()? sessionGeneration,
    bool Function(int)? isCurrentSession,
    Future<void> Function(bool)? setMediaSessionActive,
    Future<void> Function()? ensureSessionOpen,
  }) : _player = player ?? PlayerService(),
       _prepareForExit = prepareForExit ?? WidgetService().prepareForExit,
       _sessionGeneration =
           sessionGeneration ?? (() => WidgetService().sessionGeneration),
       _isCurrentSession = isCurrentSession ?? WidgetService().isCurrentSession,
       _setMediaSessionActive =
           setMediaSessionActive ?? WidgetService().setMediaSessionActive,
       _ensureSessionOpen =
           ensureSessionOpen ?? WidgetService().ensurePlaybackSessionOpen {
    _subscriptions.addAll([
      _player.currentSongStream.listen((_) => _publish()),
      _player.stateStream.listen((_) => _publish()),
      _player.positionStream.listen((_) => _publishState()),
      _player.durationStream.listen((_) => _publish()),
      _player.playlistStream.listen((_) => _publish()),
      _player.playModeStream.listen((_) => _publishState()),
      _player.transitioningStream.listen((_) => _publishState()),
    ]);
    _publish();
  }

  final PlayerService _player;
  final Future<void> Function() _prepareForExit;
  final int Function() _sessionGeneration;
  final bool Function(int) _isCurrentSession;
  final Future<void> Function(bool) _setMediaSessionActive;
  final Future<void> Function() _ensureSessionOpen;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  bool _stopped = false;
  bool _disposed = false;
  bool? _mediaSessionActive;
  int _commandGeneration = 0;
  Future<void> _sessionActivation = Future<void>.value();
  Future<void>? _disposal;

  MediaItem _mediaItem(Song song, {bool current = false}) => MediaItem(
    id: '${song.source}::${song.id}',
    title: song.name,
    artist: song.artist,
    album: song.album,
    duration: current && _player.currentDuration > Duration.zero
        ? _player.currentDuration
        : Duration(seconds: song.durationSeconds),
    artUri: song.coverUrl.isEmpty ? null : Uri.tryParse(song.coverUrl),
  );

  void _publish() {
    if (_disposed) return;
    final current = _player.currentSong;
    mediaItem.add(current == null ? null : _mediaItem(current, current: true));
    queue.add(_player.playlist.map((song) => _mediaItem(song)).toList());
    _publishState();
  }

  void _publishState() {
    if (_disposed) return;
    final playing = _player.isPlaying || _player.isTransitioning;
    if (playing) _stopped = false;
    final idle =
        _stopped ||
        _player.currentSong == null ||
        (!playing &&
            (_player.isRestoredSession ||
                _player.playerState == PlayerState.stopped ||
                _player.playerState == PlayerState.disposed));
    final processing = idle
        ? AudioProcessingState.idle
        : _player.isTransitioning
        ? AudioProcessingState.buffering
        : _player.playerState == PlayerState.completed
        ? AudioProcessingState.completed
        : AudioProcessingState.ready;
    final index = _player.currentIndex;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing && !idle) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.setSpeed,
          MediaAction.setRepeatMode,
          MediaAction.setShuffleMode,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: processing,
        playing: playing && !idle,
        updatePosition: _player.currentPosition,
        speed: _player.playbackRate,
        queueIndex: index >= 0 && index < _player.playlist.length
            ? index
            : null,
        repeatMode: switch (_player.playMode) {
          PlayMode.singleLoop => AudioServiceRepeatMode.one,
          PlayMode.sequentialPlaylists => AudioServiceRepeatMode.none,
          _ => AudioServiceRepeatMode.all,
        },
        shuffleMode: _player.playMode == PlayMode.shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
    final active = processing != AudioProcessingState.idle;
    if (_mediaSessionActive != active) {
      _mediaSessionActive = active;
      _sessionActivation = _setMediaSessionActive(active);
      unawaited(_sessionActivation);
    }
  }

  @override
  Future<void> play() async {
    final command = ++_commandGeneration;
    await _ensureSessionOpen();
    if (_disposed || command != _commandGeneration) return;
    _stopped = false;
    await _player.resume();
    _publish();
    await _sessionActivation;
  }

  @override
  Future<void> pause() async {
    _commandGeneration++;
    await _player.pause();
    _publishState();
    await _sessionActivation;
  }

  @override
  Future<void> stop() async {
    final command = ++_commandGeneration;
    final session = _sessionGeneration();
    await _player.pause();
    await _player.savePlaybackStateNow();
    if (_disposed ||
        command != _commandGeneration ||
        !_isCurrentSession(session) ||
        _player.isPlaying ||
        _player.isTransitioning) {
      return;
    }
    _stopped = true;
    _publishState();
    await super.stop();
    await _sessionActivation;
  }

  @override
  Future<void> onTaskRemoved() async {
    final command = ++_commandGeneration;
    final session = _sessionGeneration();
    await _prepareForExit();
    if (_disposed ||
        command != _commandGeneration ||
        !_isCurrentSession(session) ||
        _player.isPlaying ||
        _player.isTransitioning) {
      return;
    }
    _stopped = true;
    _publishState();
    await super.stop();
    await _sessionActivation;
  }

  @override
  Future<void> skipToNext() async {
    final command = ++_commandGeneration;
    await _ensureSessionOpen();
    if (_disposed || command != _commandGeneration) return;
    _player.playNext();
    _publish();
  }

  @override
  Future<void> skipToPrevious() async {
    final command = ++_commandGeneration;
    await _ensureSessionOpen();
    if (_disposed || command != _commandGeneration) return;
    _player.playPrev();
    _publish();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _publishState();
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _player.setPlaybackRate(speed);
    _publishState();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _player.setPlayMode(switch (repeatMode) {
      AudioServiceRepeatMode.one => PlayMode.singleLoop,
      AudioServiceRepeatMode.none => PlayMode.sequentialPlaylists,
      _ => PlayMode.listLoop,
    });
    _publishState();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (shuffleMode != AudioServiceShuffleMode.none) {
      _player.setPlayMode(PlayMode.shuffle);
    } else if (_player.playMode == PlayMode.shuffle) {
      _player.setPlayMode(PlayMode.listLoop);
    }
    _publishState();
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _commandGeneration++;
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
    _subscriptions.clear();
    await _sessionActivation;
    if (_mediaSessionActive == true) await _setMediaSessionActive(false);
    await Future.wait([
      mediaItem.close(),
      queue.close(),
      playbackState.close(),
    ]);
  }
}
