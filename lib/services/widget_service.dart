import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'player_service.dart';
import 'database_service.dart';
import '../models/song.dart';

class WidgetService {
  static final WidgetService _instance = WidgetService._internal();
  factory WidgetService() => _instance;
  WidgetService._internal();

  static const MethodChannel _channel = MethodChannel('com.dmusic.app/widget');
  bool _isInitialized = false;

  String? _lastCoverUrl;
  String? _cachedCoverPath;
  int _syncGeneration = 0;
  bool _exiting = false;
  Future<void>? _exitPreparation;
  Future<void>? _initialization;
  int _sessionGeneration = 0;
  bool? _mediaSessionActive;
  Future<void> _mediaSessionUpdate = Future<void>.value();
  Future<void> Function()? _playbackStop;

  int get sessionGeneration => _sessionGeneration;

  bool isCurrentSession(int generation) => generation == _sessionGeneration;

  void registerPlaybackStop(Future<void> Function() stop) {
    _playbackStop = stop;
  }

  Future<void> setMediaSessionActive(bool active) {
    _mediaSessionActive = active;
    final generation = _sessionGeneration;
    if (generation == 0) return Future<void>.value();
    return _mediaSessionUpdate = _mediaSessionUpdate.then((_) async {
      if (!isCurrentSession(generation)) return;
      await _channel.invokeMethod<void>('mediaSessionActive', {
        'active': active,
        'generation': generation,
      });
    });
  }

  void _openPlaybackSession(int generation) {
    if (generation <= _sessionGeneration) return;
    _sessionGeneration = generation;
    _exiting = false;
    _exitPreparation = null;
    ++_syncGeneration;
    _lastAction = '';
    _lastActionTimestamp = 0;
    if (_isInitialized) {
      final active = _mediaSessionActive;
      if (active != null) unawaited(setMediaSessionActive(active));
      unawaited(_syncWidget());
    }
  }

  Future<void> init() {
    return _initialization ??= _initialize();
  }

  Future<void> ensurePlaybackSessionOpen() async {
    await init();
    if (!_exiting) return;
    final session = await _channel.invokeMapMethod<String, dynamic>(
      'openPlaybackSession',
    );
    _openPlaybackSession(session!['generation'] as int);
  }

  Future<void> _initialize() async {
    // The bridge belongs to the service engine, so callbacks also work headless.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPlaybackSessionOpened') {
        final generation = (call.arguments as Map)['generation'] as int;
        _openPlaybackSession(generation);
      } else if (call.method == 'onTaskDismissed') {
        final generation =
            (call.arguments as Map?)?['generation'] as int? ??
            _sessionGeneration;
        if (isCurrentSession(generation)) {
          await prepareForExit();
          if (isCurrentSession(generation)) await stopPlaybackService();
        }
      } else if (call.method == 'onWidgetAction') {
        final generation = (call.arguments as Map?)?['generation'] as int?;
        if (generation != null && !isCurrentSession(generation)) return;
        final action = call.arguments?['action'] as String?;
        if (action != null) await _handleWidgetAction(action);
      }
    });

    final session = await _channel.invokeMapMethod<String, dynamic>(
      'connectPlaybackSession',
    );
    final generation = session!['generation'] as int;
    _openPlaybackSession(generation);
    _isInitialized = true;
    if (session['closed'] == true && isCurrentSession(generation)) {
      await prepareForExit();
      if (isCurrentSession(generation)) await stopPlaybackService();
    }
    final active = _mediaSessionActive;
    if (active != null) await setMediaSessionActive(active);

    PlayerService().currentSongStream.listen((song) {
      _syncWidget(song: song);
    });
    PlayerService().stateStream.listen((_) {
      _syncWidget();
    });
    PlayerService().durationStream.listen((_) {
      _syncWidget();
    });
    PlayerService().playModeStream.listen((_) {
      _syncWidget();
    });
    DatabaseService().favoritesStream.listen((_) {
      _syncWidget();
    });

    await _syncWidget();
    await _checkPendingAction();
  }

  Future<void> _checkPendingAction() async {
    try {
      final action = await _channel.invokeMethod<String>('checkPendingAction');
      if (action != null && action.isNotEmpty) {
        await _handleWidgetAction(action);
      }
    } catch (_) {}
  }

  int _lastActionTimestamp = 0;
  String _lastAction = '';

  Future<void> _handleWidgetAction(String action) async {
    if (_exiting) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 增加 350ms 防抖去重，彻底防止通知栏/控制中心与 MediaSession 双重派发导致跳过一首歌
    if (action == _lastAction && (now - _lastActionTimestamp) < 350) {
      return;
    }
    _lastAction = action;
    _lastActionTimestamp = now;

    final player = PlayerService();
    if (action.startsWith('com.dmusic.app.ACTION_SEEK:')) {
      final posStr = action.substring('com.dmusic.app.ACTION_SEEK:'.length);
      final posMs = int.tryParse(posStr);
      if (posMs != null && posMs >= 0) {
        await player.seek(Duration(milliseconds: posMs));
      }
      return;
    }

    switch (action) {
      case 'com.dmusic.app.ACTION_TOGGLE_PLAY':
        await player.togglePlay();
        break;
      case 'com.dmusic.app.ACTION_PAUSE':
        await player.pause();
        break;
      case 'com.dmusic.app.ACTION_PLAY':
        await player.resume();
        break;
      case 'com.dmusic.app.ACTION_PREV':
        player.playPrev();
        break;
      case 'com.dmusic.app.ACTION_NEXT':
        player.playNext();
        break;
      case 'com.dmusic.app.ACTION_TOGGLE_MODE':
        player.togglePlayMode();
        break;
      case 'com.dmusic.app.ACTION_TOGGLE_FAVORITE':
        final song = player.currentSong;
        if (song != null) {
          await DatabaseService().toggleFavorite(song);
          _syncWidget();
        }
        break;
    }
  }

  Future<String?> _resolveCoverPath(String coverUrl) async {
    if (coverUrl.isEmpty) return null;
    if (_lastCoverUrl == coverUrl && _cachedCoverPath != null) {
      if (File(_cachedCoverPath!).existsSync()) {
        return _cachedCoverPath;
      }
    }

    try {
      final dir = await getTemporaryDirectory();
      final hash = md5.convert(utf8.encode(coverUrl)).toString();
      final file = File('${dir.path}/widget_cover_$hash.jpg');
      if (await file.exists()) {
        _lastCoverUrl = coverUrl;
        _cachedCoverPath = file.path;
        return file.path;
      }

      final resp = await http
          .get(Uri.parse(coverUrl))
          .timeout(const Duration(seconds: 4));
      if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
        await file.writeAsBytes(resp.bodyBytes);
        _lastCoverUrl = coverUrl;
        _cachedCoverPath = file.path;
        return file.path;
      }
    } catch (_) {}
    return null;
  }

  String _formatDuration(int totalSeconds) {
    if (totalSeconds <= 0) return '00:00';
    final m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _syncWidget({Song? song}) async {
    if (_exiting || _sessionGeneration == 0) return;
    final generation = ++_syncGeneration;
    try {
      final player = PlayerService();
      final currentSong = song ?? player.currentSong;

      if (currentSong == null) {
        await _channel.invokeMethod('updateWidget', {
          'generation': _sessionGeneration,
          'title': 'DMusic 发烧播放器',
          'artist': '点击开启好音乐',
          'progress': '00:00 / 00:00',
          'isPlaying': false,
          'isFavorite': false,
          'playMode': 'listLoop',
          'quality': 'FLAC 无损',
          'coverPath': null,
          'positionMs': 0,
          'durationMs': 0,
        });
        return;
      }

      // 封面请求不能阻塞媒体状态/焦点同步。
      await _channel.invokeMethod('updateWidget', _widgetPayload(currentSong));
      if (generation != _syncGeneration) return;
      final coverPath = await _resolveCoverPath(currentSong.coverUrl);
      if (generation != _syncGeneration || coverPath == null) return;
      // 封面加载期间进度仍在变化，发送时重新读取实际播放状态和进度。
      await _channel.invokeMethod(
        'updateWidget',
        _widgetPayload(currentSong, coverPath: coverPath),
      );
    } catch (_) {}
  }

  Map<String, dynamic> _widgetPayload(Song currentSong, {String? coverPath}) {
    final player = PlayerService();
    // 获取当前进度与总时长（毫秒级，供安卓系统锁屏/控制中心无缝进度条推移与拖动 Seek）
    int durationMs = player.currentDuration.inMilliseconds;
    final dur = currentSong.durationSeconds;
    if (durationMs <= 0 && dur > 0) {
      durationMs = dur * 1000;
    }
    final positionMs = player.currentPosition.inMilliseconds;

    final durSec = durationMs > 0 ? (durationMs ~/ 1000) : dur;
    final durStr = _formatDuration(durSec);
    String progressStr = durStr;
    if (durSec > 0) {
      progressStr = 'DMusic 发烧级解码 · $durStr';
    }

    // 判断收藏状态
    final isFav = DatabaseService().isFavorite(currentSong);

    // 播放模式字符串
    String modeStr = 'listLoop';
    if (player.playMode == PlayMode.singleLoop) {
      modeStr = 'singleLoop';
    } else if (player.playMode == PlayMode.shuffle) {
      modeStr = 'shuffle';
    } else if (player.playMode == PlayMode.sequentialPlaylists) {
      modeStr = 'sequentialPlaylists';
    }

    // 音质规格徽章
    String quality = currentSong.quality;
    if (quality.isEmpty) {
      quality = currentSong.isLossless ? 'FLAC 无损' : '320k 极高';
    }

    return {
      'generation': _sessionGeneration,
      'title': currentSong.name,
      'artist': '${currentSong.artist} · ${currentSong.source}',
      'progress': progressStr,
      'isPlaying': player.isPlayingOrBuffering,
      'isFavorite': isFav,
      'playMode': modeStr,
      'quality': quality,
      'coverPath': coverPath,
      'positionMs': positionMs,
      'durationMs': durationMs,
    };
  }

  /// 外部快捷触发小组件与后台播放服务同步
  void syncWidget({Song? song}) {
    _syncWidget(song: song);
  }

  /// 立即强制同步指定播放状态到小组件（常用于应用被划掉、退出或进入离线状态时）
  Future<void> syncWidgetImmediately({bool isPlaying = false}) async {
    if (_sessionGeneration == 0) return;
    ++_syncGeneration;
    try {
      final player = PlayerService();
      final currentSong = player.currentSong;
      if (currentSong == null) {
        await _channel.invokeMethod('updateWidget', {
          'generation': _sessionGeneration,
          'title': 'DMusic 发烧播放器',
          'artist': '点击开启好音乐',
          'progress': '00:00 / 00:00',
          'isPlaying': false,
          'isFavorite': false,
          'playMode': 'listLoop',
          'quality': 'FLAC 无损',
          'coverPath': null,
          'positionMs': 0,
          'durationMs': 0,
        });
      } else {
        final payload = _widgetPayload(currentSong);
        payload['isPlaying'] = isPlaying;
        await _channel.invokeMethod('updateWidget', payload);
      }
    } catch (_) {}
  }

  Future<void> stopPlaybackService() async {
    final generation = _sessionGeneration;
    ++_syncGeneration;
    await _playbackStop?.call();
    if (generation == 0) return;
    try {
      await _channel.invokeMethod('stopPlaybackService', {
        'generation': generation,
      });
    } catch (_) {}
  }

  Future<void> prepareForExit() {
    final preparation = _exitPreparation;
    if (preparation != null) return preparation;
    final generation = _sessionGeneration;
    _exiting = true;
    ++_syncGeneration;
    final completion = Completer<void>();
    _exitPreparation = completion.future;
    unawaited(() async {
      try {
        // Close the native epoch immediately, before the player's pause fade.
        if (generation != 0) {
          try {
            await _channel.invokeMethod<void>('beginPlaybackExit', {
              'generation': generation,
            });
          } catch (_) {}
        }
        if (!isCurrentSession(generation)) return;
        try {
          await PlayerService().pause();
        } finally {
          await PlayerService().savePlaybackStateNow();
          if (isCurrentSession(generation)) {
            await syncWidgetImmediately(isPlaying: false);
          }
        }
      } finally {
        completion.complete();
      }
    }());
    return completion.future;
  }
}
