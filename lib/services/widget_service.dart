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

  void init() {
    if (_isInitialized) return;
    _isInitialized = true;

    // 监听来自 Android Widget 广播的原生点击回调
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onWidgetAction') {
        final action = call.arguments?['action'] as String?;
        if (action != null) {
          _handleWidgetAction(action);
        }
      }
    });

    // 检查是否有冷启动时暂存的 Widget Action
    _checkPendingAction();

    // 监听播放状态、歌曲切换、循环模式、总时长变动
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

    // 初始化立刻同步一次初始状态
    _syncWidget();
  }

  Future<void> _checkPendingAction() async {
    try {
      final action = await _channel.invokeMethod<String>('checkPendingAction');
      if (action != null && action.isNotEmpty) {
        _handleWidgetAction(action);
      }
    } catch (_) {}
  }

  int _lastActionTimestamp = 0;
  String _lastAction = '';

  void _handleWidgetAction(String action) async {
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
    final generation = ++_syncGeneration;
    try {
      final player = PlayerService();
      final currentSong = song ?? player.currentSong;

      if (currentSong == null) {
        await _channel.invokeMethod('updateWidget', {
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
    }

    // 音质规格徽章
    String quality = currentSong.quality;
    if (quality.isEmpty) {
      quality = currentSong.isLossless ? 'FLAC 无损' : '320k 极高';
    }

    return {
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

  Future<void> stopPlaybackService() async {
    ++_syncGeneration;
    try {
      await _channel.invokeMethod('stopPlaybackService');
    } catch (_) {}
  }
}
