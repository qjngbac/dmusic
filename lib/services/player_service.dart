import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../models/lyric.dart';
import 'music_api.dart';
import 'audio_inspector.dart';
import 'database_service.dart';
import 'widget_service.dart';
import 'playback_cache_service.dart';

class _PlaybackInput {
  final Source source;
  final Future<void> Function()? release;
  final CachedPlayback? cached;

  _PlaybackInput(this.source, {this.release, this.cached});
}

enum PlayMode {
  listLoop, // 列表循环
  singleLoop, // 单曲循环
  shuffle, // 随机播放
  sequentialPlaylists, // 歌单顺序播放
}

class PlayerService {
  static final PlayerService _instance = PlayerService._internal();
  factory PlayerService() => _instance;
  PlayerService._internal() {
    _init();
  }

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<dynamic>> _playerSubscriptions = [];
  Song? _currentSong;
  List<Song> _playlist = [];
  int _currentIndex = -1;
  final List<int> _shuffleHistory = [];

  double _playbackRate = 1.0;
  double get playbackRate => _playbackRate;

  Timer? _sleepCountdownTimer;
  DateTime? _sleepTargetTime;
  int _remainingSleepSeconds = 0;
  bool _sleepAfterCurrentSong = false;
  final _sleepTimerController = StreamController<int>.broadcast();
  Stream<int> get sleepTimerStream => _sleepTimerController.stream;
  int get remainingSleepSeconds => _remainingSleepSeconds;
  bool get isSleepTimerActive =>
      _remainingSleepSeconds > 0 || _sleepAfterCurrentSong;
  bool get sleepAfterCurrentSong => _sleepAfterCurrentSong;

  // 歌词与双语翻译
  List<LrcLine> _currentLyrics = [];
  String? _rawLyricText;
  String? _rawTransLyricText;
  int _lyricOffsetMs = 0;
  bool _showTranslation = true;

  final _lyricsController = StreamController<List<LrcLine>>.broadcast();
  Stream<List<LrcLine>> get lyricsStream => _lyricsController.stream;
  List<LrcLine> get currentLyrics => _currentLyrics;

  final _lyricOffsetController = StreamController<int>.broadcast();
  Stream<int> get lyricOffsetStream => _lyricOffsetController.stream;
  int get lyricOffsetMs => _lyricOffsetMs;

  final _showTranslationController = StreamController<bool>.broadcast();
  Stream<bool> get showTranslationStream => _showTranslationController.stream;
  bool get showTranslation => _showTranslation;

  // 播放模式
  PlayMode _playMode = PlayMode.listLoop;
  final _playModeController = StreamController<PlayMode>.broadcast();
  Stream<PlayMode> get playModeStream => _playModeController.stream;
  PlayMode get playMode => _playMode;

  String get playModeName {
    switch (_playMode) {
      case PlayMode.listLoop:
        return '列表循环';
      case PlayMode.singleLoop:
        return '单曲循环';
      case PlayMode.shuffle:
        return '随机播放';
      case PlayMode.sequentialPlaylists:
        return '歌单顺序播放';
    }
  }

  // 播放队列监听流
  final _playlistController = StreamController<List<Song>>.broadcast();
  Stream<List<Song>> get playlistStream => _playlistController.stream;

  final _stateController = StreamController<PlayerState>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _songController = StreamController<Song?>.broadcast();
  final _errorController = StreamController<String>.broadcast();

  Stream<PlayerState> get stateStream => _stateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration> get durationStream => _durationController.stream;
  Stream<Song?> get currentSongStream => _songController.stream;
  Stream<String> get errorStream => _errorController.stream;

  final _transitioningController = StreamController<bool>.broadcast();
  Stream<bool> get transitioningStream => _transitioningController.stream;
  DateTime? _lastToggleTime;
  String? _currentCustomPlaylistId;
  String? get currentCustomPlaylistId => _currentCustomPlaylistId;

  void _setTransitioning(bool value) {
    _isTransitioning = value;
    _transitioningController.add(value);
  }

  Song? get currentSong => _currentSong;
  bool _isTransitioning = false;
  bool get isTransitioning => _isTransitioning;
  bool get isPlaying => _player.state == PlayerState.playing;
  bool get isPlayingOrBuffering =>
      _isTransitioning || _player.state == PlayerState.playing;
  PlayerState get playerState => _player.state;
  List<Song> get playlist => List.unmodifiable(_playlist);
  int get currentIndex => _currentIndex;
  int _consecutiveErrors = 0;

  // 防卡死看门狗（Watchdog）
  Timer? _stallWatchdogTimer;
  int _stallSeconds = 0;
  bool _watchdogRecoveryInFlight = false;
  int _watchdogGeneration = 0;

  // 预加载相关
  Duration _currentDuration = Duration.zero;
  bool _isPreloading = false;
  String? _preloadedSongId;
  Duration? _pendingSeekPosition;

  // 播放断点记忆与无缝续播状态
  Duration _lastKnownPosition = Duration.zero;
  Duration get currentPosition => _lastKnownPosition;
  Duration get currentDuration => _currentDuration;
  bool _isRestoredSession = false;
  bool get isRestoredSession => _isRestoredSession;
  Timer? _saveDebounceTimer;
  DateTime _lastSaveTime = DateTime.fromMillisecondsSinceEpoch(0);

  // 切歌并发与时序保护令牌（防止连续快速切歌导致时序倒错或旧请求覆盖新请求）
  int _playSessionId = 0;
  int _lyricSessionId = 0;
  bool _qualitySwitchInProgress = false;
  Future<void> _nativeSourceQueue = Future.value();
  Future<void> Function()? _releasePlaybackLease;
  Source? _activePlaybackSource;
  final List<Future<void> Function()> _retainedPlaybackLeases = [];
  CachedPlayback? _activeCachedPlayback;

  String _requestedQuality(Song song) {
    final quality = song.audioUrlQuality;
    return quality == null || quality.isEmpty || quality == 'auto'
        ? '256k'
        : quality;
  }

  Future<void> _releaseLease(Future<void> Function()? release) async {
    try { await release?.call(); } catch (_) {}
  }

  Future<void> _adoptInput(_PlaybackInput? input) async {
    final oldReleases = [
      ?_releasePlaybackLease,
      ..._retainedPlaybackLeases,
    ];
    _retainedPlaybackLeases.clear();
    _activePlaybackSource = input?.source;
    _releasePlaybackLease = input?.release;
    _activeCachedPlayback = input?.cached;
    for (final release in oldReleases) { await _releaseLease(release); }
  }

  Future<void> _stopSource({int? sessionId}) => _serializeNativeSource(() async {
    if (sessionId != null && sessionId != _playSessionId) return;
    // release() confirms native file/network resources have been torn down.
    await _player.release();
    await _adoptInput(null);
  });

  Future<CachedPlayback?> _findCached(Song song, String quality) async {
    try {
      return await PlaybackCacheService.instance.find(song, targetQuality: quality);
    } catch (_) { return null; }
  }

  Future<_PlaybackInput> _onlineInput(Song song, String url) async {
    try {
      final source = await PlaybackCacheService.instance.createSource(song, url);
      return _PlaybackInput(UrlSource(source.uri.toString()), release: source.release);
    } catch (_) {
      return _PlaybackInput(UrlSource(url));
    }
  }

  Future<void> _serializeNativeSource(Future<void> Function() action) {
    final operation = _nativeSourceQueue.then((_) => action());
    _nativeSourceQueue = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _playSource(Source source, {
    Duration? position,
    int? sessionId,
    Future<void> Function()? release,
    CachedPlayback? cached,
  }) {
    final session = sessionId ?? _playSessionId;
    return _serializeNativeSource(() async {
      if (session != _playSessionId) {
        await _releaseLease(release);
        return;
      }
      try {
        await _player.play(source, position: position);
      } catch (_) {
        // Dart's Source is assigned before native preparation completes.
        // Retain both leases until a confirmed replacement or native release.
        if (release != null) _retainedPlaybackLeases.add(release);
        rethrow;
      }
      await _adoptInput(_PlaybackInput(source, release: release, cached: cached));
      _applyNativeEq();
    });
  }

  Future<void> _playOnlineSource(Song song, String url, {Duration? position}) async {
    final session = _playSessionId;
    final input = await _onlineInput(song, url);
    await _playSource(input.source, position: position, sessionId: session,
        release: input.release);
  }

  // 10段专业发烧均衡器（EQ）
  static const List<String> eqBandFrequencies = [
    '31Hz',
    '62Hz',
    '125Hz',
    '250Hz',
    '500Hz',
    '1kHz',
    '2kHz',
    '4kHz',
    '8kHz',
    '16kHz',
  ];

  static const Map<String, List<double>> eqPresets = {
    '纯净原声': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    '黑胶暖音': [3.0, 2.5, 1.5, 0.5, 0.0, 0.0, -1.0, -2.0, -3.0, -4.0],
    '超重低音': [6.0, 5.0, 4.0, 2.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0],
    '清亮人声': [-2.0, -1.0, 0.0, 2.0, 4.5, 4.0, 3.0, 1.5, 0.5, 0.0],
    '3D环绕': [3.0, 1.5, -1.0, -2.0, 0.0, 2.0, 3.5, 4.0, 4.0, 3.0],
  };

  String _currentEqPreset = '纯净原声';
  List<double> _eqBands = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
  final _eqController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get eqStream => _eqController.stream;
  String get currentEqPreset => _currentEqPreset;
  List<double> get eqBands => List.unmodifiable(_eqBands);

  static const MethodChannel _nativeChannel = MethodChannel('com.dmusic.app/widget');

  void setEqPreset(String name) {
    if (eqPresets.containsKey(name)) {
      _currentEqPreset = name;
      _eqBands = List<double>.from(eqPresets[name]!);
      _eqController.add({'preset': _currentEqPreset, 'bands': _eqBands});
      _applyNativeEq();
    }
  }

  void setEqBand(int index, double gain) {
    if (index >= 0 && index < _eqBands.length) {
      _eqBands[index] = gain.clamp(-12.0, 12.0);
      _currentEqPreset = '自定义';
      _eqController.add({'preset': _currentEqPreset, 'bands': _eqBands});
      _applyNativeEq();
    }
  }

  void resetEq() {
    setEqPreset('纯净原声');
  }

  Future<void> _applyNativeEq() async {
    try {
      await _nativeChannel.invokeMethod('setEqualizerBands', {'gains': _eqBands});
    } catch (_) {}
  }

  Future<bool> openSystemEqualizer() async {
    try {
      final res = await _nativeChannel.invokeMethod<bool>('openSystemEqualizer');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  void _notifyPlaylist() {
    _playlistController.add(List.unmodifiable(_playlist));
  }

  void togglePlayMode() {
    switch (_playMode) {
      case PlayMode.listLoop:
        _playMode = PlayMode.singleLoop;
        break;
      case PlayMode.singleLoop:
        _playMode = PlayMode.shuffle;
        break;
      case PlayMode.shuffle:
        _playMode = PlayMode.sequentialPlaylists;
        break;
      case PlayMode.sequentialPlaylists:
        _playMode = PlayMode.listLoop;
        break;
    }
    _playModeController.add(_playMode);
    _scheduleSavePlaybackState();
  }

  void setPlayMode(PlayMode mode) {
    _playMode = mode;
    _playModeController.add(_playMode);
    _scheduleSavePlaybackState();
  }

  void toggleTranslation() {
    _showTranslation = !_showTranslation;
    _showTranslationController.add(_showTranslation);
  }

  void adjustLyricOffset(int deltaMs) {
    _lyricOffsetMs += deltaMs;
    _lyricOffsetController.add(_lyricOffsetMs);
    if (_rawLyricText != null && _rawLyricText!.isNotEmpty) {
      _currentLyrics = LyricParser.parse(
        _rawLyricText!,
        transLrcText: _rawTransLyricText,
        offsetMs: _lyricOffsetMs,
      );
      _lyricsController.add(_currentLyrics);
    }
  }

  void resetLyricOffset() {
    _lyricOffsetMs = 0;
    _lyricOffsetController.add(0);
    if (_rawLyricText != null && _rawLyricText!.isNotEmpty) {
      _currentLyrics = LyricParser.parse(
        _rawLyricText!,
        transLrcText: _rawTransLyricText,
        offsetMs: 0,
      );
      _lyricsController.add(_currentLyrics);
    }
  }

  void removeFromPlaylist(int index) {
    if (index >= 0 && index < _playlist.length) {
      final isCurrent = index == _currentIndex;
      _playlist.removeAt(index);
      if (_playlist.isEmpty) {
        stop();
      } else if (isCurrent) {
        _currentIndex = _currentIndex.clamp(0, _playlist.length - 1);
        playSong(_playlist[_currentIndex]);
      } else if (index < _currentIndex) {
        _currentIndex -= 1;
      }
      _notifyPlaylist();
      _scheduleSavePlaybackState();
    }
  }

  void removeSongFromPlaylist(Song song) {
    final idx = _playlist.indexWhere(
      (s) => s.id == song.id && s.source == song.source,
    );
    if (idx != -1) {
      removeFromPlaylist(idx);
    }
  }

  void clearPlaylist() {
    _playSessionId++;
    _playlist.clear();
    _shuffleHistory.clear();
    _currentIndex = -1;
    _notifyPlaylist();
    _clearSavedPlaybackState();
  }

  /// 当歌曲被删除时，安全同步播放引擎与播放队列：
  /// 1. 若当前正在播放的曲目被删除：先停止播放释放底层文件句柄，防止磁盘文件被锁无法删除；
  /// 2. 从播放列表中彻底剔除被删除的曲目；
  /// 3. 若队列为空，彻底清空播放器状态并隐藏迷你条；
  /// 4. 若队列中还有其它歌曲，自动顺延切播下一首有效曲目。
  Future<void> handleSongsDeleted(List<String> deletedIds) async {
    if (deletedIds.isEmpty) return;
    final current = _currentSong;
    final isCurrentDeleted =
        current != null &&
        (deletedIds.contains(current.key) || deletedIds.contains(current.id));

    if (isCurrentDeleted) {
      _cancelStallWatchdog();
      _setTransitioning(false);
      _playSessionId++;
      await _stopSource();
      // 等待底层音频驱动完全释放文件句柄，防止 Windows/Android 文件被占用报错 (M8-2)
      await Future.delayed(const Duration(milliseconds: 80));
    }

    _playlist.removeWhere(
      (s) => deletedIds.contains(s.key) || deletedIds.contains(s.id),
    );
    _shuffleHistory.removeWhere((idx) => idx >= _playlist.length);

    if (_playlist.isEmpty) {
      _currentSong = null;
      _currentIndex = -1;
      _songController.add(null);
      _notifyPlaylist();
      WidgetService().stopPlaybackService();
      _clearSavedPlaybackState();
    } else if (isCurrentDeleted) {
      _currentIndex = _currentIndex.clamp(0, _playlist.length - 1);
      final nextSong = _playlist[_currentIndex];
      playSong(nextSong);
    } else {
      if (current != null) {
        final newIdx = _playlist.indexWhere(
          (s) =>
              s.key == current.key ||
              (s.id == current.id && s.source == current.source),
        );
        if (newIdx != -1) {
          _currentIndex = newIdx;
        }
      }
      _notifyPlaylist();
      _scheduleSavePlaybackState();
    }
  }

  void insertNext(Song song) {
    if (_playlist.isEmpty) {
      playSong(song);
      return;
    }
    final existingIdx = _playlist.indexWhere(
      (s) => s.id == song.id && s.source == song.source,
    );
    if (existingIdx != -1) {
      if (existingIdx == _currentIndex) return; // 正在播放当前歌曲无需插队
      _playlist.removeAt(existingIdx);
      if (existingIdx < _currentIndex) {
        _currentIndex -= 1;
      }
    }
    final insertPos = (_currentIndex >= 0 && _currentIndex < _playlist.length)
        ? _currentIndex + 1
        : _playlist.length;
    _playlist.insert(insertPos, song);
    _notifyPlaylist();
    _scheduleSavePlaybackState();
  }

  void reorderPlaylist(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _playlist.length) return;
    if (newIndex < 0 || newIndex > _playlist.length) return;
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final song = _playlist.removeAt(oldIndex);
    _playlist.insert(newIndex, song);

    if (_currentIndex == oldIndex) {
      _currentIndex = newIndex;
    } else if (oldIndex < _currentIndex && newIndex >= _currentIndex) {
      _currentIndex -= 1;
    } else if (oldIndex > _currentIndex && newIndex <= _currentIndex) {
      _currentIndex += 1;
    }
    _notifyPlaylist();
    _scheduleSavePlaybackState();
  }

  void _init() {
    // 显式配置 TimerPositionUpdater 替代默认的 FramePositionUpdater
    // 彻底解决手机灭屏熄屏时 Flutter UI 停止渲染 VSYNC 导致进度停止、预加载失效的问题
    _player.positionUpdater = TimerPositionUpdater(
      getPosition: _player.getCurrentPosition,
      interval: const Duration(milliseconds: 500),
    );

    try {
      AudioPlayer.global.setAudioContext(
        AudioContextConfig(stayAwake: true).build(),
      );
      _player.setAudioContext(
        AudioContext(
          android: AudioContextAndroid(
            isSpeakerphoneOn: false,
            stayAwake: true,
            contentType: AndroidContentType.music,
            usageType: AndroidUsageType.media,
            audioFocus: AndroidAudioFocus.none,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: {},
          ),
        ),
      );
    } catch (_) {}
    _player.setReleaseMode(ReleaseMode.stop);

    _playerSubscriptions.add(
      _player.onPlayerStateChanged.listen((state) {
        if (state == PlayerState.playing) {
          _consecutiveErrors = 0;
          _setTransitioning(false);
        }
        _stateController.add(state);
      }),
    );
    _playerSubscriptions.add(
      _player.onPositionChanged.listen((pos) {
        _lastKnownPosition = pos;
        _positionController.add(pos);
        _scheduleSavePlaybackState();
        if (pos > const Duration(seconds: 1) && _stallWatchdogTimer != null) {
          _cancelStallWatchdog();
        }
        if (_pendingSeekPosition != null && _currentDuration > Duration.zero) {
          final seekTo = _pendingSeekPosition!;
          _pendingSeekPosition = null;
          try {
            _player.seek(seekTo);
          } catch (_) {
            _pendingSeekPosition = seekTo;
          }
        }
        _checkAndPreload(pos);
      }),
    );
    _playerSubscriptions.add(
      _player.onDurationChanged.listen((dur) {
        if (dur > Duration.zero) {
          _currentDuration = dur;
          _durationController.add(dur);
          _scheduleSavePlaybackState();
          WidgetService().syncWidget();
        }
        if (_pendingSeekPosition != null && dur > Duration.zero) {
          final seekTo = _pendingSeekPosition!;
          _pendingSeekPosition = null;
          try {
            _player.seek(seekTo);
          } catch (_) {
            _pendingSeekPosition = seekTo;
          }
        }
      }),
    );
    _playerSubscriptions.add(
      _player.onPlayerComplete.listen((_) {
        _handleSongComplete();
      }),
    );

    // 监听底层原生媒体报错事件，防止底层出现网络断流/解码异常时无声无息卡死在00:00
    _playerSubscriptions.add(
      _player.eventStream.listen(
        (event) {
          if (event.eventType == AudioEventType.log) {
            final msg = (event.logMessage ?? '').toLowerCase();
            if (msg.contains('error') ||
                msg.contains('failed') ||
                msg.contains('media_error')) {
              _triggerWatchdogRecovery('底层音频流报告异常');
            }
          }
        },
        onError: (_) {
          _triggerWatchdogRecovery('音频通道异常');
        },
      ),
    );
  }

  void _cancelStallWatchdog() {
    _stallWatchdogTimer?.cancel();
    _stallWatchdogTimer = null;
    _stallSeconds = 0;
    _watchdogGeneration++;
    _watchdogRecoveryInFlight = false;
  }

  void _triggerWatchdogRecovery(String reason) async {
    final song = _currentSong;
    final session = _playSessionId;
    if (song == null || song.localFilePath != null) return;
    try {
      final pos = await _player.getCurrentPosition() ?? Duration.zero;
      if (session == _playSessionId &&
          _currentSong?.key == song.key &&
          pos <= const Duration(seconds: 1) &&
          _player.state != PlayerState.paused) {
        _stallSeconds = 5; // 加速触发看门狗自愈
      }
    } catch (_) {}
  }

  void _startStallWatchdog(Song song) {
    _cancelStallWatchdog();
    if (song.localFilePath != null) return;
    final session = _playSessionId;
    final generation = _watchdogGeneration;
    var recoveryStage = 0;
    bool isCurrent() =>
        session == _playSessionId && _currentSong?.key == song.key;
    _stallSeconds = 0;
    _stallWatchdogTimer = Timer.periodic(const Duration(seconds: 2), (
      timer,
    ) async {
      if (!isCurrent()) {
        _cancelStallWatchdog();
        return;
      }
      if (_watchdogRecoveryInFlight || _player.state == PlayerState.paused) {
        return; // 用户主动暂停不判定为卡死
      }
      _watchdogRecoveryInFlight = true;
      try {
        final pos = await _player.getCurrentPosition() ?? Duration.zero;
        if (!isCurrent()) return;
        if (pos > const Duration(seconds: 1)) {
          _cancelStallWatchdog();
          return;
        }
        _stallSeconds += 2;
        final quality = _requestedQuality(song);
        final nextStage = _stallSeconds >= 12 ? 2 : _stallSeconds >= 6 ? 1 : 0;
        if (nextStage > recoveryStage) {
          recoveryStage = nextStage;
          final cached = _activeCachedPlayback;
          if (cached != null) {
            await PlaybackCacheService.instance.invalidate(cached.key);
            if (!isCurrent()) return;
          }
          final candidate = song.copyWith();
          final url = nextStage == 1
              ? await MusicApi.resolveAudioUrl(
                  candidate,
                  targetQuality: quality,
                  forPlayback: true,
                  forceRefresh: true,
                  excludedUrls: {if (song.audioUrl != null) song.audioUrl!},
                )
              : await MusicApi.resolveCrossSource(
                  candidate,
                  targetQuality: quality,
                  forPlayback: true,
                  excludedUrls: {if (song.audioUrl != null) song.audioUrl!},
                );
          if (!isCurrent()) return;
          if (url != null && url.isNotEmpty) {
            await _stopSource();
            if (!isCurrent()) return;
            await _player.setVolume(1.0);
            if (!isCurrent()) return;
            await _playOnlineSource(candidate, url);
            if (!isCurrent()) return;
            _currentSong = candidate;
            _playlist[_currentIndex] = candidate;
            _songController.add(candidate);
            _notifyPlaylist();
            return;
          }
        }
        if (_stallSeconds >= 16 && isCurrent()) {
          _cancelStallWatchdog();
          _handlePlayError(song, '网络流响应超时，已自动切至下一首');
        }
      } catch (_) {
        // Keep the timer alive for the next recovery stage.
      } finally {
        if (generation == _watchdogGeneration) {
          _watchdogRecoveryInFlight = false;
        }
      }
    });
  }

  // 提前 15 秒静默预加载下一首直链
  void _checkAndPreload(Duration pos) {
    if (_currentDuration.inSeconds <= 20) return;
    final remainingSec = _currentDuration.inSeconds - pos.inSeconds;
    if (remainingSec <= 15 && remainingSec > 0 && !_isPreloading) {
      final nextSong = _peekNextSong();
      if (_activeCachedPlayback != null && nextSong?.key == _currentSong?.key) {
        return;
      }
      if (nextSong != null &&
          nextSong.key != _preloadedSongId &&
          nextSong.localFilePath == null) {
        _isPreloading = true;
        _preloadedSongId = nextSong.key;
        (() async {
          final cached = await _findCached(nextSong, _requestedQuality(nextSong));
          if (cached != null) {
            await _releaseLease(cached.release);
            return;
          }
          await MusicApi.resolveAudioUrl(nextSong.copyWith(),
              targetQuality: _requestedQuality(nextSong), forPlayback: true);
        })()
            .then((_) {
              _isPreloading = false;
            })
            .catchError((_) {
              _isPreloading = false;
            });
      }
    }
  }

  Song? _peekNextSong() {
    if (_playlist.isEmpty) return null;
    if (_playlist.length == 1) return _playlist[0];
    if (_playMode == PlayMode.singleLoop) return _currentSong;
    if (_playMode == PlayMode.shuffle) {
      final rand = Random();
      int nextIdx = rand.nextInt(_playlist.length);
      if (nextIdx == _currentIndex && _playlist.length > 1) {
        nextIdx = (nextIdx + 1) % _playlist.length;
      }
      return _playlist[nextIdx];
    }
    final nextIdx = (_currentIndex + 1) % _playlist.length;
    return _playlist[nextIdx];
  }

  int _fadeToken = 0;

  Future<void> _fadeVolume({
    required double from,
    required double to,
    Duration duration = const Duration(milliseconds: 300),
  }) async {
    final currentToken = ++_fadeToken;
    const steps = 6;
    final stepDuration = duration.inMilliseconds ~/ steps;
    final stepDelta = (to - from) / steps;
    for (int i = 1; i <= steps; i++) {
      if (currentToken != _fadeToken) return;
      final vol = (from + stepDelta * i).clamp(0.0, 1.0);
      try {
        await _player.setVolume(vol);
      } catch (_) {}
      await Future.delayed(Duration(milliseconds: stepDuration));
    }
    if (currentToken == _fadeToken) {
      try {
        await _player.setVolume(to);
      } catch (_) {}
    }
  }

  void _handleSongComplete() async {
    _cancelStallWatchdog();
    if (_currentSong == null || _isTransitioning) return;

    if (_sleepAfterCurrentSong) {
      cancelSleepTimer();
      await pause();
      return;
    }

    if (_playMode == PlayMode.singleLoop) {
      // 单曲循环：直接重新起播当前曲目
      await playSong(_currentSong!);
    } else {
      // 列表循环 / 随机播放：自动顺延切播下一首曲目
      playNext();
    }
  }

  void setPlaylist(List<Song> list, {int startIndex = 0, String? playlistId}) {
    _playlist = List.from(list);
    _shuffleHistory.clear();
    _currentCustomPlaylistId = playlistId;
    _notifyPlaylist();
    if (_playlist.isEmpty) {
      _currentIndex = -1;
      return;
    }
    final targetIndex = (startIndex >= 0 && startIndex < _playlist.length) ? startIndex : 0;
    _currentIndex = targetIndex;
    playSong(_playlist[targetIndex]);
  }

  Future<void> _loadLyrics(Song song) async {
    final int lyricSession = ++_lyricSessionId;
    _currentLyrics = [];
    _lyricsController.add(_currentLyrics);

    String? lrcText;
    String? transLrcText;

    if (song.lrcPath != null) {
      final f = File(song.lrcPath!);
      if (f.existsSync()) {
        try {
          lrcText = await f.readAsString();
        } catch (_) {}
      }
    }
    if (lyricSession != _lyricSessionId) return;

    if (lrcText == null || lrcText.isEmpty) {
      lrcText = song.lyric;
      transLrcText = song.transLyric;
    }
    if (lrcText == null || lrcText.isEmpty) {
      lrcText = await MusicApi.fetchLyric(song);
      transLrcText = song.transLyric;
    }
    if (lyricSession != _lyricSessionId) return;

    _rawLyricText = lrcText;
    _rawTransLyricText = transLrcText;
    _lyricOffsetMs = 0;
    _lyricOffsetController.add(0);

    if (lrcText != null && lrcText.isNotEmpty) {
      _currentLyrics = LyricParser.parse(
        lrcText,
        transLrcText: transLrcText,
        offsetMs: _lyricOffsetMs,
      );
      if (lyricSession == _lyricSessionId) {
        _lyricsController.add(_currentLyrics);
      }
    }
  }

  Future<void> setPlaybackRate(double rate) async {
    _playbackRate = rate;
    try {
      await _player.setPlaybackRate(rate);
    } catch (_) {}
  }

  void setSleepTimer({int? minutes, bool afterCurrentSong = false}) {
    cancelSleepTimer();
    if (afterCurrentSong) {
      _sleepAfterCurrentSong = true;
      _remainingSleepSeconds = 0;
      _sleepTimerController.add(-1);
      return;
    }
    if (minutes != null && minutes > 0) {
      _sleepAfterCurrentSong = false;
      _sleepTargetTime = DateTime.now().add(Duration(minutes: minutes));
      _remainingSleepSeconds = minutes * 60;
      _sleepTimerController.add(_remainingSleepSeconds);
      _sleepCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
        timer,
      ) {
        if (_sleepTargetTime == null) {
          timer.cancel();
          return;
        }
        final remaining = _sleepTargetTime!
            .difference(DateTime.now())
            .inSeconds;
        if (remaining > 0) {
          _remainingSleepSeconds = remaining;
          _sleepTimerController.add(_remainingSleepSeconds);
        } else {
          cancelSleepTimer();
          pause();
        }
      });
    }
  }

  void cancelSleepTimer() {
    _sleepCountdownTimer?.cancel();
    _sleepCountdownTimer = null;
    _sleepTargetTime = null;
    _remainingSleepSeconds = 0;
    _sleepAfterCurrentSong = false;
    _sleepTimerController.add(0);
  }

  void _handlePlayError(Song song, String reason) {
    _cancelStallWatchdog();
    _setTransitioning(false);
    _consecutiveErrors++;
    _errorController.add('《${song.name}》$reason');
    if (_consecutiveErrors < min(5, _playlist.length) && _playlist.length > 1) {
      playNext();
    } else {
      _consecutiveErrors = 0;
      pause(); // 熔断保护：整队连续失败时主动暂停，避免死循环切歌
    }
  }

  Future<void> playSong(Song song, {Duration? initialPosition}) async {
    final int sessionId = ++_playSessionId;
    _qualitySwitchInProgress = false;
    _setTransitioning(true);
    _cancelStallWatchdog();
    _isRestoredSession = false;
    _pendingSeekPosition =
        initialPosition != null && initialPosition > Duration.zero
        ? initialPosition
        : null;

    try {
      // 智能本地已有感知 (建议1)：若当前曲目未附带本地路径，优先比对曲库已下载文件实现零网络开销秒播
      Song playableSong = song.copyWith();
      RealAudioInfo? localAudioInfo;
      if (playableSong.localFilePath == null ||
          !File(playableSong.localFilePath!).existsSync()) {
        final match = DatabaseService().checkDownloadStatus(song);
        if (match.isExact && match.matchedSong?.localFilePath != null) {
          final localFile = File(match.matchedSong!.localFilePath!);
          if (localFile.existsSync()) {
            final info = await AudioInspector.inspect(
              localFile,
              durationSeconds: song.durationSeconds,
            );
            if (sessionId != _playSessionId) return;
            if (info.isValid && info.matchesDuration(song.durationSeconds)) {
              localAudioInfo = info;
              playableSong = song.copyWith(
                localFilePath: match.matchedSong!.localFilePath,
                lrcPath: match.matchedSong!.lrcPath,
                quality: Song.cleanQuality(info.qualityLabel.isNotEmpty ? info.qualityLabel : song.quality),
                isLossless: info.isLossless,
                fileSizeBytes: info.fileSizeBytes,
              );
            }
          }
        }
      }
      if (playableSong.localFilePath != null && localAudioInfo == null) {
        final file = File(playableSong.localFilePath!);
        if (await file.exists()) {
          final info = await AudioInspector.inspect(
            file,
            durationSeconds: playableSong.durationSeconds,
          );
          if (sessionId != _playSessionId) return;
          if (info.isValid && info.matchesDuration(playableSong.durationSeconds)) {
            localAudioInfo = info;
            playableSong = playableSong.copyWith(
              quality: Song.cleanQuality(info.qualityLabel.isNotEmpty ? info.qualityLabel : playableSong.quality),
              isLossless: info.isLossless,
              fileSizeBytes: info.fileSizeBytes,
            );
          }
        }
      }

      // 若当前正在播放，执行快速淡出
      if (_player.state == PlayerState.playing) {
        await _fadeVolume(
          from: 1.0,
          to: 0.0,
          duration: const Duration(milliseconds: 150),
        );
      }
      if (sessionId != _playSessionId) return;

      _currentSong = playableSong;
      if (initialPosition != null && initialPosition > Duration.zero) {
        _lastKnownPosition = initialPosition;
        _positionController.add(initialPosition);
        final dur = playableSong.durationSeconds > 0
            ? Duration(seconds: playableSong.durationSeconds)
            : _currentDuration;
        if (dur > Duration.zero) {
          _currentDuration = dur;
          _durationController.add(dur);
        }
      } else {
        _currentDuration = playableSong.durationSeconds > 0
            ? Duration(seconds: playableSong.durationSeconds)
            : Duration.zero;
        _durationController.add(_currentDuration);
        _positionController.add(Duration.zero);
        _lastKnownPosition = Duration.zero;
      }
      _preloadedSongId = null;

      final idx = _playlist.indexWhere((s) => s.key == playableSong.key);
      if (idx != -1) {
        _currentIndex = idx;
        _playlist[idx] = playableSong;
      } else {
        if (_playlist.isEmpty) {
          _playlist = [playableSong];
          _currentIndex = 0;
        } else {
          final insertPos =
              (_currentIndex >= 0 && _currentIndex < _playlist.length)
              ? _currentIndex + 1
              : _playlist.length;
          _playlist.insert(insertPos, playableSong);
          _currentIndex = insertPos;
        }
      }
      _notifyPlaylist();
      _songController.add(_currentSong);

      // 异步加载歌词
      _loadLyrics(playableSong);

      // 自动记入本地播放历史
      DatabaseService().addHistory(playableSong);

      // 1. 若为本地已下载文件，优先以离线模式点播
      if (localAudioInfo != null && playableSong.localFilePath != null) {
        try {
          await _player.setVolume(0.0);
          if (sessionId != _playSessionId) return;
          await _playSource(
            DeviceFileSource(playableSong.localFilePath!),
            position: _pendingSeekPosition,
          );
          if (sessionId != _playSessionId) return;
          if (_playbackRate != 1.0) {
            await _player.setPlaybackRate(_playbackRate);
          }
          _setTransitioning(false);
          _fadeVolume(
            from: 0.0,
            to: 1.0,
            duration: const Duration(milliseconds: 250),
          );
          if (_pendingSeekPosition != null) {
            final seekTo = _pendingSeekPosition!;
            _pendingSeekPosition = null;
            try {
              await _player.seek(seekTo);
            } catch (_) {
              _pendingSeekPosition = seekTo;
            }
          }
          _scheduleSavePlaybackState(force: true);
          return;
        } catch (_) {}
      }

      // 若为本地源（本地/本地扫描/本地转换），本地文件无效时不触发网络搜索
      if (playableSong.source == '本地' ||
          playableSong.source == '本地扫描' ||
          playableSong.source == '本地转换') {
        if (sessionId != _playSessionId) return;
        _setTransitioning(false);
        _handlePlayError(playableSong, '本地音频文件不存在或已损坏');
        return;
      }
      if (playableSong.localFilePath != null) {
        playableSong = playableSong.copyWith(
          localFilePath: null,
          lrcPath: null,
        );
        _currentSong = playableSong;
        _playlist[_currentIndex] = playableSong;
      }

      // 2. 解析网络流直链播放
      // Resolve on the playback copy so catalog data keeps its original metadata.
      final requestedQuality = _requestedQuality(playableSong);
      final cached = await _findCached(playableSong, requestedQuality);
      if (sessionId != _playSessionId) {
        await _releaseLease(cached?.release);
        return;
      }
      if (cached != null) {
        var handedToPlayer = false;
        try {
          await _player.setVolume(0.0);
          if (sessionId != _playSessionId) return;
          handedToPlayer = true;
          await _playSource(DeviceFileSource(cached.file.path),
              position: _pendingSeekPosition, sessionId: sessionId,
              release: cached.release, cached: cached);
          if (sessionId != _playSessionId) return;
          playableSong = cached.song.copyWith(audioUrlQuality: requestedQuality);
          _currentSong = playableSong;
          _playlist[_currentIndex] = playableSong;
          _songController.add(playableSong);
          _notifyPlaylist();
          _startStallWatchdog(playableSong);
          if (_playbackRate != 1.0) await _player.setPlaybackRate(_playbackRate);
          _setTransitioning(false);
          _fadeVolume(from: 0.0, to: 1.0,
              duration: const Duration(milliseconds: 250));
          _scheduleSavePlaybackState(force: true);
          return;
        } catch (_) {
          if (sessionId != _playSessionId) return;
          try { await PlaybackCacheService.instance.invalidate(cached.key); } catch (_) {}
        } finally {
          if (!handedToPlayer) await _releaseLease(cached.release);
        }
      }
      String? url = await MusicApi.resolveAudioUrl(
        playableSong,
        targetQuality: requestedQuality,
        forPlayback: true,
      );
      if (sessionId != _playSessionId) return;
      if (url == null || url.isEmpty) {
        final fallback = await MusicApi.resolveCrossSource(
          playableSong,
          targetQuality: requestedQuality,
          forPlayback: true,
        );
        if (sessionId != _playSessionId) return;
        if (fallback != null && fallback.isNotEmpty) {
          url = fallback;
        }
      }

      if (url == null || url.isEmpty) {
        if (sessionId != _playSessionId) return;
        _setTransitioning(false);
        _handlePlayError(playableSong, '无法获取可播放音频直链');
        return;
      }

      // 启动防卡在00:00的超时自愈看门狗哨兵
      _startStallWatchdog(playableSong);

      try {
        await _player.setVolume(0.0);
        if (sessionId != _playSessionId) return;
        await _playOnlineSource(playableSong, url, position: _pendingSeekPosition);
        if (sessionId != _playSessionId) return;
        _songController.add(playableSong);
        _notifyPlaylist();
        if (_playbackRate != 1.0) {
          await _player.setPlaybackRate(_playbackRate);
        }
        _fadeVolume(
          from: 0.0,
          to: 1.0,
          duration: const Duration(milliseconds: 250),
        );
        _setTransitioning(false);
        if (_pendingSeekPosition != null && _currentDuration > Duration.zero) {
          final seekTo = _pendingSeekPosition!;
          _pendingSeekPosition = null;
          try {
            await _player.seek(seekTo);
          } catch (_) {
            _pendingSeekPosition = seekTo;
          }
        }
        _scheduleSavePlaybackState(force: true);
      } catch (_) {
        if (sessionId != _playSessionId) return;
        // 直链失效重试
        try {
          final refreshedUrl = await MusicApi.resolveAudioUrl(
            playableSong,
            targetQuality: requestedQuality,
            forPlayback: true,
            forceRefresh: true,
          );
          if (sessionId != _playSessionId) return;
          if (refreshedUrl != null && refreshedUrl.isNotEmpty) {
            await _player.setVolume(0.0);
            if (sessionId != _playSessionId) return;
            await _playOnlineSource(
              playableSong, refreshedUrl,
              position: _pendingSeekPosition,
            );
            if (sessionId != _playSessionId) return;
            _songController.add(playableSong);
            _notifyPlaylist();
            if (_playbackRate != 1.0) {
              await _player.setPlaybackRate(_playbackRate);
            }
            _fadeVolume(
              from: 0.0,
              to: 1.0,
              duration: const Duration(milliseconds: 250),
            );
            _setTransitioning(false);
            if (_pendingSeekPosition != null &&
                _currentDuration > Duration.zero) {
              final seekTo = _pendingSeekPosition!;
              _pendingSeekPosition = null;
              try {
                await _player.seek(seekTo);
              } catch (_) {
                _pendingSeekPosition = seekTo;
              }
            }
            _scheduleSavePlaybackState(force: true);
            return;
          }
        } catch (_) {}

        // 跨源保底
        try {
          final fallback = await MusicApi.resolveCrossSource(
            playableSong,
            targetQuality: requestedQuality,
            forPlayback: true,
          );
          if (sessionId != _playSessionId) return;
          if (fallback != null && fallback.isNotEmpty) {
            await _player.setVolume(0.0);
            if (sessionId != _playSessionId) return;
            await _playOnlineSource(
              playableSong, fallback,
              position: _pendingSeekPosition,
            );
            if (sessionId != _playSessionId) return;
            _songController.add(playableSong);
            _notifyPlaylist();
            if (_playbackRate != 1.0) {
              await _player.setPlaybackRate(_playbackRate);
            }
            _fadeVolume(
              from: 0.0,
              to: 1.0,
              duration: const Duration(milliseconds: 250),
            );
            _setTransitioning(false);
            if (_pendingSeekPosition != null &&
                _currentDuration > Duration.zero) {
              final seekTo = _pendingSeekPosition!;
              _pendingSeekPosition = null;
              try {
                await _player.seek(seekTo);
              } catch (_) {
                _pendingSeekPosition = seekTo;
              }
            }
            _scheduleSavePlaybackState(force: true);
            return;
          }
        } catch (_) {}

        if (sessionId == _playSessionId) {
          _setTransitioning(false);
          _handlePlayError(song, '网络流解码失败');
        }
      }
    } catch (_) {
      if (sessionId == _playSessionId) {
        _setTransitioning(false);
        _handlePlayError(song, '播放器异常');
      }
    }
  }

  // 动态切换音质并热重载
  Future<void> switchQuality(Song song, String newQuality) async {
    final quality = switch (newQuality.toLowerCase()) {
      'flac' || 'flac 无损' || '无损' => 'flac',
      '256' || '256k' || '256k 高品' => '256k',
      '320k' || '320k 极高' => '320k',
      '128k' || '128k 标准' => '128k',
      _ => null,
    };
    final current = _currentSong;
    if (quality == null ||
        current == null ||
        current.key != song.key ||
        current.localFilePath != null) {
      _errorController.add('当前歌曲不支持所选音质切换');
      throw StateError('当前歌曲不支持所选音质切换');
    }
    final session = ++_playSessionId;
    _qualitySwitchInProgress = true;
    _cancelStallWatchdog();
    bool isCurrent() =>
        session == _playSessionId && _currentSong?.key == current.key;
    final wasPlaying = _player.state == PlayerState.playing;
    _PlaybackInput? input;
    var handedToPlayer = false;
    try {
      final position = await _player.getCurrentPosition() ?? _lastKnownPosition;
      if (!isCurrent()) throw StateError('歌曲已切换');
      var updatedSong = current.copyWith(
        audioUrl: null,
        audioUrlTimestamp: null,
        audioUrlQuality: quality,
        audioUrlSource: null,
      );
      final cached = await _findCached(updatedSong, quality);
      if (cached != null) {
        input = _PlaybackInput(DeviceFileSource(cached.file.path),
            release: cached.release, cached: cached);
        updatedSong = cached.song.copyWith(audioUrlQuality: quality);
      } else {
        final newUrl = await MusicApi.resolveAudioUrl(
          updatedSong,
          targetQuality: quality,
          forPlayback: true,
          forceRefresh: true,
        );
        if (!isCurrent()) throw StateError('歌曲已切换');
        if (newUrl == null || newUrl.isEmpty) throw StateError('所选音质暂无可用音源');
        input = await _onlineInput(updatedSong, newUrl);
      }
      if (!isCurrent()) throw StateError('歌曲已切换');
      await _serializeNativeSource(() async {
        if (!isCurrent()) throw StateError('歌曲或播放意图已改变');
        final previousSource = _activePlaybackSource;
        var sourceChanged = false;
        var sourceAccepted = false;
        var rollbackAttempted = false;
        var restored = false;
        try {
          if (wasPlaying) await _player.pause();
          if (!isCurrent()) throw StateError('歌曲已切换');
          sourceChanged = true;
          await _player.setSource(input!.source);
          sourceAccepted = true;
          if (!isCurrent()) throw StateError('歌曲已切换');
          await _player.seek(position);
          if (!isCurrent()) throw StateError('歌曲已切换');
          if (wasPlaying) await _player.resume();
          if (!isCurrent()) throw StateError('歌曲已切换');
        } catch (_) {
          if (isCurrent()) {
            try {
              if (sourceChanged && previousSource != null) {
                rollbackAttempted = true;
                await _player.setSource(previousSource);
                restored = true;
                if (isCurrent()) await _player.seek(position);
              }
              if (isCurrent() && wasPlaying) await _player.resume();
            } catch (_) {
              if (isCurrent()) _isRestoredSession = true;
            }
          }
          rethrow;
        } finally {
          // A retired request still owns its native source until the queued
          // replacement/pause runs. Never close that source's proxy early.
          if (sourceAccepted && !rollbackAttempted) {
            handedToPlayer = true;
            await _adoptInput(input!);
          } else if (sourceChanged && !restored && input!.release != null) {
            handedToPlayer = true;
            _retainedPlaybackLeases.add(input.release!);
          }
        }
      });
      if (!isCurrent()) throw StateError('歌曲或播放意图已改变');
      _lastKnownPosition = position;
      _currentSong = updatedSong;
      final idx = _playlist.indexWhere((s) => s.key == current.key);
      if (idx != -1) _playlist[idx] = updatedSong;
      _songController.add(updatedSong);
      _notifyPlaylist();
      _scheduleSavePlaybackState(force: true);
    } catch (error) {
      _errorController.add('音质切换失败：$error');
      throw StateError('音质切换失败：$error');
    } finally {
      if (!handedToPlayer) await _releaseLease(input?.release);
      if (session == _playSessionId) _qualitySwitchInProgress = false;
    }
  }

  Future<void> togglePlay() async {
    final now = DateTime.now();
    if (_lastToggleTime != null &&
        now.difference(_lastToggleTime!) < const Duration(milliseconds: 500)) {
      return; // 500ms 快速点击防抖
    }
    _lastToggleTime = now;
    if (_isTransitioning) {
      return; // 缓冲加载中，防重复打断
    }
    if (_player.state == PlayerState.playing) {
      await pause();
    } else {
      if (_currentSong != null) {
        await resume();
      }
    }
  }

  Future<void> pause() async {
    if (_isTransitioning || _qualitySwitchInProgress) _isRestoredSession = true;
    final session = ++_playSessionId;
    _qualitySwitchInProgress = false;
    _cancelStallWatchdog();
    _setTransitioning(false);
    if (_player.state == PlayerState.playing) {
      await _fadeVolume(
        from: 1.0,
        to: 0.0,
        duration: const Duration(milliseconds: 180),
      );
    }
    if (session != _playSessionId) return;
    await _serializeNativeSource(() async {
      if (session == _playSessionId) await _player.pause();
    });
    if (session != _playSessionId) return;
    try {
      await _player.setVolume(1.0);
    } catch (_) {}
    _scheduleSavePlaybackState(force: true);
  }

  Future<void> resume() async {
    if (_currentSong == null) return;
    if (_qualitySwitchInProgress) _isRestoredSession = true;
    _playSessionId++;
    _qualitySwitchInProgress = false;
    if (_isRestoredSession || _player.state != PlayerState.paused) {
      _isRestoredSession = false;
      await playSong(
        _currentSong!,
        initialPosition: _pendingSeekPosition ?? _lastKnownPosition,
      );
      return;
    }
    try {
      await _player.setVolume(0.0);
    } catch (_) {}
    await _serializeNativeSource(() => _player.resume());
    _fadeVolume(
      from: 0.0,
      to: 1.0,
      duration: const Duration(milliseconds: 250),
    );
    _scheduleSavePlaybackState(force: true);
  }

  Future<void> stop() async {
    final session = ++_playSessionId;
    _qualitySwitchInProgress = false;
    _cancelStallWatchdog();
    _setTransitioning(false);
    await _stopSource(sessionId: session);
    if (session != _playSessionId) return;
    _currentSong = null;
    _songController.add(null);
    WidgetService().stopPlaybackService();
    _clearSavedPlaybackState();
  }

  Future<void> seek(Duration pos) async {
    if (_currentSong == null) return;

    // 限制 seek 范围，防止超过总时长触发底层完播跳下一首
    Duration target = pos;
    if (target < Duration.zero) target = Duration.zero;
    if (_currentDuration > const Duration(seconds: 2) && target >= _currentDuration) {
      target = _currentDuration - const Duration(milliseconds: 800);
      if (target < Duration.zero) target = Duration.zero;
    }

    _lastKnownPosition = target;
    _positionController.add(target);
    _scheduleSavePlaybackState(force: true);

    // 若当前为冷启动恢复会话且尚未起播，暂存目标跳转进度，等用户点击播放时使用
    if (_isRestoredSession) {
      _pendingSeekPosition = target;
      return;
    }

    // 若歌曲正处于换歌过渡中，或底层总时长尚未就绪，暂存目标跳转进度，等音频就绪后自动跳转，杜绝误切下一首
    if (_isTransitioning || _currentDuration == Duration.zero) {
      _pendingSeekPosition = target;
      return;
    }

    try {
      _pendingSeekPosition = null;
      await _player.seek(target);
      WidgetService().syncWidget();
    } catch (_) {
      _pendingSeekPosition = target;
    }
  }

  void playNext() {
    if (_playlist.isEmpty) return;
    if (_playlist.length == 1) {
      if (_playMode == PlayMode.sequentialPlaylists && _advanceToNextSequentialPlaylist()) {
        return;
      }
      playSong(_playlist[0]);
      return;
    }
    if (_playMode == PlayMode.sequentialPlaylists) {
      if (_currentIndex >= _playlist.length - 1) {
        if (_advanceToNextSequentialPlaylist()) {
          return;
        }
      }
      _currentIndex = (_currentIndex + 1) % _playlist.length;
    } else if (_playMode == PlayMode.shuffle) {
      if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
        _shuffleHistory.add(_currentIndex);
        if (_shuffleHistory.length > 100) {
          _shuffleHistory.removeAt(0);
        }
      }
      final rand = Random();
      int nextIdx = rand.nextInt(_playlist.length);
      if (nextIdx == _currentIndex) {
        nextIdx = (nextIdx + 1 + rand.nextInt(_playlist.length - 1)) % _playlist.length;
      }
      _currentIndex = nextIdx;
    } else {
      _currentIndex = (_currentIndex + 1) % _playlist.length;
    }
    playSong(_playlist[_currentIndex]);
  }

  /// 跨歌单顺序连播核心接续逻辑：
  /// 顺延至用户自定义排定顺序的下一个歌单并无缝起播第 1 首歌
  bool _advanceToNextSequentialPlaylist() {
    final customPlaylists = DatabaseService().playlists;
    if (customPlaylists.isEmpty) return false;

    int curIdx = -1;
    if (_currentCustomPlaylistId != null) {
      curIdx = customPlaylists.indexWhere((p) => p.id == _currentCustomPlaylistId);
    }
    if (curIdx == -1 && _currentSong != null) {
      curIdx = customPlaylists.indexWhere(
        (p) => p.songs.any((s) => s.key == _currentSong!.key || s.id == _currentSong!.id),
      );
    }
    if (curIdx == -1) {
      curIdx = 0;
    }

    for (int step = 1; step <= customPlaylists.length; step++) {
      final nextIdx = (curIdx + step) % customPlaylists.length;
      final candidate = customPlaylists[nextIdx];
      if (candidate.songs.isNotEmpty) {
        setPlaylist(candidate.songs, startIndex: 0, playlistId: candidate.id);
        return true;
      }
    }
    return false;
  }

  void playPrev() {
    if (_playlist.isEmpty) return;
    if (_playlist.length == 1) {
      playSong(_playlist[0]);
      return;
    }
    if (_playMode == PlayMode.shuffle) {
      if (_shuffleHistory.isNotEmpty) {
        _currentIndex = _shuffleHistory.removeLast();
      } else {
        _currentIndex = (_currentIndex - 1 + _playlist.length) % _playlist.length;
      }
    } else {
      _currentIndex = (_currentIndex - 1 + _playlist.length) % _playlist.length;
    }
    playSong(_playlist[_currentIndex]);
  }

  // ================= 播放断点记忆与无缝续播持久化 =================
  Future<File> _getPlaybackStateFile() async {
    final appDir = await getApplicationDocumentsDirectory();
    return File('${appDir.path}/dmusic_playback_state.json');
  }

  /// 立即强制保存当前播放断点状态（退出应用、退至后台、切歌或暂停时同步保存）
  Future<void> savePlaybackStateNow() async {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    await _savePlaybackStateToFile();
  }

  void _scheduleSavePlaybackState({bool force = false}) {
    if (_currentSong == null) return;
    final now = DateTime.now();
    if (force || now.difference(_lastSaveTime).inSeconds >= 3) {
      _saveDebounceTimer?.cancel();
      _saveDebounceTimer = null;
      _lastSaveTime = now;
      _savePlaybackStateToFile();
    } else {
      _saveDebounceTimer ??= Timer(const Duration(seconds: 3), () {
        _saveDebounceTimer = null;
        _lastSaveTime = DateTime.now();
        _savePlaybackStateToFile();
      });
    }
  }

  Future<void> _savePlaybackStateToFile() async {
    final song = _currentSong;
    if (song == null) return;
    try {
      final file = await _getPlaybackStateFile();
      final data = {
        'song': song.toJson(),
        'positionMs': _lastKnownPosition.inMilliseconds,
        'durationMs': _currentDuration.inMilliseconds,
        'playlist': _playlist.map((s) => s.toJson()).toList(),
        'currentIndex': _currentIndex,
        'playModeIndex': _playMode.index,
        'customPlaylistId': _currentCustomPlaylistId,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      await file.writeAsString(jsonEncode(data), flush: true);
    } catch (_) {}
  }

  Future<void> _clearSavedPlaybackState() async {
    try {
      _saveDebounceTimer?.cancel();
      _saveDebounceTimer = null;
      final file = await _getPlaybackStateFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  /// 冷启动恢复上次播放断点会话
  Future<void> restorePlaybackState() async {
    try {
      final file = await _getPlaybackStateFile();
      if (!await file.exists()) return;
      final content = await file.readAsString();
      if (content.isEmpty) return;
      final map = jsonDecode(content) as Map<String, dynamic>;
      if (map['song'] == null) return;

      final restoredSong = Song.fromJson(map['song'] as Map<String, dynamic>);
      final rawList = map['playlist'] as List? ?? [];
      final restoredPlaylist = rawList
          .map((item) => Song.fromJson(item as Map<String, dynamic>))
          .toList();
      final restoredIdx = (map['currentIndex'] as int? ?? 0).clamp(
        0,
        restoredPlaylist.isNotEmpty ? restoredPlaylist.length - 1 : 0,
      );
      final playModeIdx = map['playModeIndex'] as int? ?? 0;
      final posMs = map['positionMs'] as int? ?? 0;
      final durMs = map['durationMs'] as int? ?? 0;

      // 1. 恢复播放模式
      if (playModeIdx >= 0 && playModeIdx < PlayMode.values.length) {
        _playMode = PlayMode.values[playModeIdx];
        _playModeController.add(_playMode);
      }
      _currentCustomPlaylistId = map['customPlaylistId'] as String?;

      // 2. 恢复播放队列
      if (restoredPlaylist.isNotEmpty) {
        _playlist = restoredPlaylist;
        _currentIndex = restoredIdx;
        _notifyPlaylist();
      } else {
        _playlist = [restoredSong];
        _currentIndex = 0;
        _notifyPlaylist();
      }

      // 3. 恢复歌曲与时间轴
      _currentSong = restoredSong;
      var pos = Duration(milliseconds: posMs);
      final dur = durMs > 0
          ? Duration(milliseconds: durMs)
          : (restoredSong.durationSeconds > 0
              ? Duration(seconds: restoredSong.durationSeconds)
              : Duration.zero);

      // 若退出时停留在歌曲末尾（最后3秒内），则重置回起点 00:00，防止起播立即切下一首
      if (dur > const Duration(seconds: 10) && pos >= dur - const Duration(seconds: 3)) {
        pos = Duration.zero;
      }

      _lastKnownPosition = pos;
      _currentDuration = dur;
      _pendingSeekPosition = pos > Duration.zero ? pos : null;
      _isRestoredSession = true;

      // 4. 派发广播通知 UI 立即呈现
      _songController.add(_currentSong);
      _positionController.add(pos);
      _durationController.add(dur);
      _stateController.add(PlayerState.paused);

      // 5. 异步预载歌词，以便点开播放器界面立即可见对应歌词行
      _loadLyrics(restoredSong);
    } catch (_) {}
  }

  Future<void> dispose() async {
    _playSessionId++;
    _lyricSessionId++;
    _fadeToken++;
    _qualitySwitchInProgress = false;
    _saveDebounceTimer?.cancel();
    _cancelStallWatchdog();
    _setTransitioning(false);
    _sleepCountdownTimer?.cancel();
    await _nativeSourceQueue;
    await _player.dispose();
    await _adoptInput(null);
    await PlaybackCacheService.instance.dispose();
    for (final subscription in _playerSubscriptions) {
      await subscription.cancel();
    }
    await Future.wait([
      _sleepTimerController.close(),
      _lyricsController.close(),
      _lyricOffsetController.close(),
      _showTranslationController.close(),
      _playlistController.close(),
      _eqController.close(),
      _playModeController.close(),
      _stateController.close(),
      _positionController.close(),
      _durationController.close(),
      _songController.close(),
      _errorController.close(),
      _transitioningController.close(),
    ]);
  }
}
