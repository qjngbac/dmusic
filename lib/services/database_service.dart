import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/search_preferences.dart';
import 'audio_inspector.dart';
import 'download_service.dart';
import 'player_service.dart';

enum DownloadMatchStatus {
  notDownloaded, // 未下载
  exactMatch,    // 完全匹配（同一版本已在曲库）
  baseTitleMatch // 同名异版（去括号后主歌名一致，如原版 vs Live版）
}

class DownloadMatchResult {
  final DownloadMatchStatus status;
  final Song? matchedSong;
  final bool canUpgrade; // 是否本地音质低于当前线上版本（可升级无损）

  const DownloadMatchResult({
    required this.status,
    this.matchedSong,
    this.canUpgrade = false,
  });

  bool get isDownloaded => status != DownloadMatchStatus.notDownloaded;
  bool get isExact => status == DownloadMatchStatus.exactMatch;
  bool get isVariant => status == DownloadMatchStatus.baseTitleMatch;
}

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  bool _initialized = false;
  File? _dbFile;

  static const List<String> defaultSources = ['网易云', 'QQ音乐', '酷狗音乐', '酷我音乐', '咪咕音乐', '哔哩哔哩', '汽水音乐'];
  final List<Song> _downloads = [];
  // Unreadable/uncertain old files keep their recovery metadata on disk.
  final List<Song> _unverifiedDownloads = [];
  final List<Song> _favorites = [];
  final List<Song> _history = [];
  final List<String> _searchHistory = [];
  final List<CustomPlaylist> _playlists = [];
  List<String> _enabledSources = List.from(defaultSources);
  SearchPreferences _searchPreferences = SearchPreferences();

  final _downloadsController = StreamController<List<Song>>.broadcast();
  final _favoritesController = StreamController<List<Song>>.broadcast();
  final _historyController = StreamController<List<Song>>.broadcast();
  final _searchHistoryController = StreamController<List<String>>.broadcast();
  final _playlistsController = StreamController<List<CustomPlaylist>>.broadcast();

  List<Song> get downloads => List.unmodifiable(_downloads);
  List<Song> get favorites => List.unmodifiable(_favorites);
  List<Song> get history => List.unmodifiable(_history);
  List<String> get searchHistory => List.unmodifiable(_searchHistory);
  List<CustomPlaylist> get playlists => List.unmodifiable(_playlists);
  List<String> get enabledSources => List.unmodifiable(_enabledSources);
  SearchPreferences get searchPreferences => _searchPreferences;

  Future<void> saveSearchPreferences(SearchPreferences preferences) async {
    await init();
    _searchPreferences = preferences;
    await _persist(immediate: true);
  }

  Future<void> saveEnabledSources(List<String> sources) async {
    if (sources.isEmpty) {
      _enabledSources = List.from(defaultSources);
    } else {
      _enabledSources = List.from(sources);
    }
    await _persist();
  }

  Stream<List<Song>> get downloadsStream => _downloadsController.stream;
  Stream<List<Song>> get favoritesStream => _favoritesController.stream;
  Stream<List<Song>> get historyStream => _historyController.stream;
  Stream<List<String>> get searchHistoryStream => _searchHistoryController.stream;
  Stream<List<CustomPlaylist>> get playlistsStream => _playlistsController.stream;

  /// 检查歌曲在已下载曲库中的匹配状态（智能区分完全匹配、同名异版与音质升级状态）
  DownloadMatchResult checkDownloadStatus(Song song, [List<Song>? list]) {
    final pool = list ?? _downloads;
    if (pool.isEmpty) {
      return const DownloadMatchResult(status: DownloadMatchStatus.notDownloaded);
    }

    final cleanCandidateName = Song.cleanTitle(song.name);
    final candidateRank = song.qualityRank;

    // 辅助函数：校验本地文件是否存在，若已被外部删除则异步清理并返回 false
    bool isSongFileAlive(Song s) {
      if (s.localFilePath == null) return false;
      final file = File(s.localFilePath!);
      if (!AudioInspector.isQuickValidAudioFile(file)) {
        // 发现被外部删除或损坏的孤儿文件，排队异步从曲库清理
        scheduleMicrotask(() => cleanMissingLocalDownloads());
        return false;
      }
      return true;
    }

    // 1. 优先完全精准匹配 (ID及源相同，或完全同名同歌手)
    for (final d in pool) {
      final isIdMatch = d.id == song.id && d.source == song.source;
      final isExactNameMatch = d.name.trim().toLowerCase() == song.name.trim().toLowerCase() &&
          d.artist.trim().toLowerCase() == song.artist.trim().toLowerCase() &&
          Song.isArtistMatch(d.artist, song.artist);
      if (isIdMatch || isExactNameMatch) {
        if (!isSongFileAlive(d)) continue;
        final downloadedRank = d.qualityRank;
        final canUpgrade = (song.isLossless && downloadedRank < 4) || (candidateRank > downloadedRank);
        return DownloadMatchResult(
          status: DownloadMatchStatus.exactMatch,
          matchedSong: d,
          canUpgrade: canUpgrade,
        );
      }
    }

    // 2. 去除中英文各类括号修饰后的主歌名匹配 (如本地已有《晴天》，搜索为《晴天 (Live)》)
    for (final d in pool) {
      final cleanDownloadedName = Song.cleanTitle(d.name);
      if (cleanDownloadedName == cleanCandidateName &&
          Song.isArtistMatch(d.artist, song.artist)) {
        if (!isSongFileAlive(d)) continue;
        final downloadedRank = d.qualityRank;
        final canUpgrade = (song.isLossless && downloadedRank < 4) || (candidateRank > downloadedRank);
        return DownloadMatchResult(
          status: DownloadMatchStatus.baseTitleMatch,
          matchedSong: d,
          canUpgrade: canUpgrade,
        );
      }
    }

    return const DownloadMatchResult(status: DownloadMatchStatus.notDownloaded);
  }

  bool _hasLoadFailure = false;
  bool _loadedFromBackup = false;
  Timer? _debounceTimer;
  Future<void> _persistQueue = Future<void>.value();

  Future<String?> _readValidLibrary(File file) async {
    try {
      final raw = await file.readAsString();
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      for (final key in ['downloads', 'favorites', 'history', 'playlists']) {
        if (data[key] is! List) return null;
        for (final item in data[key]) {
          if (item is! Map) return null;
          if (key == 'playlists') {
            CustomPlaylist.fromJson(Map<String, dynamic>.from(item));
          } else {
            Song.fromJson(Map<String, dynamic>.from(item));
          }
        }
      }
      for (final key in ['searchHistory', 'enabledSources']) {
        if (data.containsKey(key) && data[key] is! List) return null;
      }
      return raw;
    } catch (_) {
      return null;
    }
  }

  Future<void> init() async {
    if (_initialized) return;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _dbFile = File('${appDir.path}/dmusic_library.json');
      final bakFile = File('${appDir.path}/dmusic_library.json.bak');

      final mainExists = await _dbFile!.exists();
      final backupExists = await bakFile.exists();
      String? content = mainExists ? await _readValidLibrary(_dbFile!) : null;
      if (content == null && backupExists) {
        content = await _readValidLibrary(bakFile);
        _loadedFromBackup = content != null;
      }
      _hasLoadFailure = content == null && (mainExists || backupExists);

      if (content != null && content.isNotEmpty) {
        dynamic decoded;
        try {
          decoded = jsonDecode(content);
        } catch (_) {}
        if (decoded is Map) {
          final data = Map<String, dynamic>.from(decoded);
          _searchPreferences = SearchPreferences.fromJson(data['searchPreferences']);
          if (data['downloads'] is List) {
            _downloads.clear();
            _unverifiedDownloads.clear();
            for (final item in data['downloads']) {
              if (item is Map) {
                try {
                  final song = Song.fromJson(Map<String, dynamic>.from(item));
                  _downloads.add(song);
                } catch (_) {}
              }
            }
          }
          if (data['favorites'] is List) {
            _favorites.clear();
            for (final item in data['favorites']) {
              if (item is Map) {
                try {
                  _favorites.add(Song.fromJson(Map<String, dynamic>.from(item)));
                } catch (_) {}
              }
            }
          }
          if (data['history'] is List) {
            _history.clear();
            for (final item in data['history']) {
              if (item is Map) {
                try {
                  _history.add(Song.fromJson(Map<String, dynamic>.from(item)));
                } catch (_) {}
              }
            }
          }
          if (data['searchHistory'] is List) {
            _searchHistory.clear();
            for (final item in data['searchHistory']) {
              if (item != null) {
                _searchHistory.add(item.toString());
              }
            }
          }
          if (data['playlists'] is List) {
            _playlists.clear();
            for (final item in data['playlists']) {
              if (item is Map) {
                try {
                  _playlists.add(CustomPlaylist.fromJson(Map<String, dynamic>.from(item)));
                } catch (_) {}
              }
            }
          }
          if (data['enabledSources'] is List) {
            try {
              final loaded = (data['enabledSources'] as List).map((e) => e.toString()).toList();
              if (loaded.isNotEmpty) {
                _enabledSources = loaded;
                if (!_enabledSources.contains('汽水音乐') && _enabledSources.length >= 6) {
                  _enabledSources.add('汽水音乐');
                }
              }
            } catch (_) {}
          }
        }
      }
      _initialized = true;
      _notifyAll();
    } catch (_) {
      // 读取失败时保留原文件，禁止以不完整的内存状态覆盖它。
      _hasLoadFailure = true;
      _initialized = true;
      _notifyAll();
    }
  }

  Future<void> _persist({bool immediate = false}) async {
    if (_dbFile == null) {
      if (immediate) throw StateError('数据库目录不可用，不能保存');
      return;
    }
    if (_hasLoadFailure) {
      if (immediate) throw StateError('数据库读取失败，原文件已保留，不能覆盖');
      return;
    }

    if (!immediate) {
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 500), () {
        _doPersist().catchError((Object _) {});
      });
      return;
    }

    _debounceTimer?.cancel();
    await _doPersist();
  }

  Future<void> _doPersist() {
    _persistQueue = _persistQueue.catchError((Object _) {}).then((_) => _writeLibrary());
    return _persistQueue;
  }

  Future<void> _writeLibrary() async {
    if (_dbFile == null) throw StateError('数据库目录不可用，不能保存');
    if (_hasLoadFailure) throw StateError('数据库读取失败，原文件已保留，不能覆盖');
    final map = {
      'downloads': [
        ..._downloads.map((s) => s.toJson()),
        ..._unverifiedDownloads
            .where((s) => !_downloads.any((current) => current.key == s.key))
            .map((s) => s.toJson()),
      ],
      'favorites': _favorites.map((s) => s.toJson()).toList(),
      'history': _history.map((s) => s.toJson()).toList(),
      'searchHistory': _searchHistory,
      'playlists': _playlists.map((p) => p.toJson()).toList(),
      'enabledSources': _enabledSources,
      'searchPreferences': _searchPreferences.toJson(),
    };
    final jsonStr = jsonEncode(map);
    final tmpFile = File('${_dbFile!.path}.tmp');
    await tmpFile.writeAsString(jsonStr, flush: true);

    // 从备份恢复后的首次写入，不以损坏主库覆盖有效备份。
    if (!_loadedFromBackup && await _dbFile!.exists()) {
      try {
        final bakFile = File('${_dbFile!.path}.bak');
        await _dbFile!.copy(bakFile.path);
      } catch (_) {}
    }

    // 原子重命名替换
    await tmpFile.rename(_dbFile!.path);
    _loadedFromBackup = false;
  }

  void _notifyAll() {
    _downloadsController.add(List.from(_downloads));
    _favoritesController.add(List.from(_favorites));
    _historyController.add(List.from(_history));
    _searchHistoryController.add(List.from(_searchHistory));
    _playlistsController.add(List.from(_playlists));
  }

  /// 清理手机文件管理器等外部手段删除后的无效下载记录（双向自动感知）
  Future<int> cleanMissingLocalDownloads() async {
    await init();
    final missing = <Song>[];
    for (final s in _downloads) {
      if (s.localFilePath != null) {
        final f = File(s.localFilePath!);
        if (!AudioInspector.isQuickValidAudioFile(f)) {
          missing.add(s);
        }
      } else {
        missing.add(s);
      }
    }
    if (missing.isNotEmpty) {
      _downloads.removeWhere((s) => missing.any((m) => m.id == s.id && m.source == s.source));
      await _persist(immediate: true);
      _notifyAll();
    }
    return missing.length;
  }

  /// Restore existing files referenced by saved tasks; never fetch, rename or
  /// overwrite them, and never replace a newer registered download.
  Future<void> restoreExistingDownloads(Iterable<Song> songs) async {
    await init();
    final inserted = <Song>[];
    for (final song in songs) {
      if (_downloads.any((current) => current.key == song.key)) continue;
      _downloads.add(song);
      inserted.add(song);
    }
    if (inserted.isEmpty) return;
    try {
      await _persist(immediate: true);
    } catch (_) {
      _downloads.removeWhere((song) => inserted.any((added) => identical(added, song)));
      rethrow;
    }
    _unverifiedDownloads.removeWhere((song) => inserted.any((added) => added.key == song.key));
    _downloadsController.add(List.from(_downloads));
  }

  /// 记录已下载歌曲到数据库 (经真实魔数检测修正格式、标签与大小)
  Future<Song> addDownload(Song song, File file, {String? lrcPath, bool Function()? isCurrent}) async {
    void checkCurrent() {
      if (isCurrent != null && !isCurrent()) throw StateError('下载任务已取消');
    }
    await init();
    checkCurrent();
    var info = await AudioInspector.inspect(file, durationSeconds: song.durationSeconds, strict: true);
    checkCurrent();
    if (!info.isValid || info.hasVideo) {
      throw const FormatException('文件不是有效的纯音频或结构校验未通过，未加入曲库');
    }
    File finalFile = file;
    if (!file.path.toLowerCase().endsWith('.${info.realExtension}')) {
      final basePath = file.path.replaceFirst(RegExp(r'\.[a-zA-Z0-9]+$'), '');
      var newPath = '$basePath.${info.realExtension}';
      var suffix = 1;
      while (true) {
        try {
          // 独占占位，避免并发下载选中同一路径后覆盖已有录音。
          await File(newPath).create(exclusive: true);
          break;
        } on FileSystemException {
          if (!await File(newPath).exists()) rethrow;
          newPath = '${basePath}_${suffix++}.${info.realExtension}';
        }
      }
      try {
        finalFile = await file.rename(newPath);
      } catch (_) {
        // 仅清理本次创建的空占位文件；原音频仍保留。
        try {
          await File(newPath).delete();
        } catch (_) {}
      }
    }
    checkCurrent();

    final downloadedSong = song.copyWith(
      quality: Song.cleanQuality(info.qualityLabel),
      size: info.sizeMb,
      durationSeconds: info.durationSeconds > 0 ? info.durationSeconds : song.durationSeconds,
      isLossless: info.isLossless,
      localFilePath: finalFile.path,
      lrcPath: lrcPath ?? song.lrcPath,
      fileSizeBytes: info.fileSizeBytes,
      downloadTime: DateTime.now(),
    );

    // 替换同一来源的歌曲记录；其他版本和旧音频文件保留，删除须由用户明确操作。
    checkCurrent();
    final previous = _downloads.where((s) => s.key == song.key).toList();
    _downloads.removeWhere((s) => s.key == song.key);
    _downloads.insert(0, downloadedSong);
    try {
      await _persist(immediate: true);
      checkCurrent();
    } catch (_) {
      // 仅回滚本次插入；同一歌曲若已被新任务更新，不干扰新记录。
      final insertedIndex = _downloads.indexWhere((s) => identical(s, downloadedSong));
      if (insertedIndex != -1) {
        _downloads.removeAt(insertedIndex);
        _downloads.insertAll(insertedIndex, previous);
        try {
          await _persist(immediate: true);
        } catch (_) {}
        _downloadsController.add(List.from(_downloads));
      }
      rethrow;
    }
    _downloadsController.add(List.from(_downloads));
    _unverifiedDownloads.removeWhere((existing) => existing.key == song.key);
    return downloadedSong;
  }

  /// 批量删除已下载曲目 (物理删除音频文件与歌词文件，并更新数据库)
  Future<int> batchDeleteDownloads(List<String> idsOrKeys) async {
    await init();
    // 释放正在播放的歌曲文件占用，同步播放队列防报错
    await PlayerService().handleSongsDeleted(idsOrKeys);
    final keySet = idsOrKeys.toSet();
    final toRemove = _downloads.where((s) => keySet.contains(s.key) || keySet.contains(s.id)).toList();
    for (final song in toRemove) {
      if (song.localFilePath != null) {
        try {
          final f = File(song.localFilePath!);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      if (song.lrcPath != null) {
        try {
          final lrc = File(song.lrcPath!);
          if (await lrc.exists()) await lrc.delete();
        } catch (_) {}
      }
      // 从下载队列中清理该曲目，确保用户可随时重新下载
      DownloadService().removeTask(song.id, source: song.source);
    }

    _downloads.removeWhere((s) => keySet.contains(s.key) || keySet.contains(s.id));
    _unverifiedDownloads.removeWhere((s) => keySet.contains(s.key) || keySet.contains(s.id));
    await _persist();
    _downloadsController.add(List.from(_downloads));
    return toRemove.length;
  }

  /// 从数据库与手机磁盘物理删除单首下载
  Future<bool> deleteDownload(String songIdOrKey) async {
    await init();
    // 释放正在播放的歌曲文件占用，同步播放队列防报错
    await PlayerService().handleSongsDeleted([songIdOrKey]);
    final index = _downloads.indexWhere((s) => s.key == songIdOrKey || s.id == songIdOrKey);
    if (index == -1) return false;

    final song = _downloads[index];
    try {
      if (song.localFilePath != null) {
        final f = File(song.localFilePath!);
        if (await f.exists()) {
          await f.delete();
        }
      }
      if (song.lrcPath != null) {
        final lrc = File(song.lrcPath!);
        if (await lrc.exists()) {
          await lrc.delete();
        }
      }
    } catch (_) {}

    // 从下载队列中清理该曲目，确保用户可随时重新下载
    DownloadService().removeTask(song.id, source: song.source);

    _downloads.removeAt(index);
    _unverifiedDownloads.removeWhere((s) => s.key == song.key);
    await _persist();
    _downloadsController.add(List.from(_downloads));
    return true;
  }

  /// 切换收藏状态
  Future<bool> toggleFavorite(Song song) async {
    await init();
    final exists = isFavorite(song);
    if (exists) {
      _favorites.removeWhere((s) => s.id == song.id && s.source == song.source);
    } else {
      _favorites.insert(0, song);
    }
    await _persist();
    _favoritesController.add(List.from(_favorites));
    return !exists;
  }

  bool isFavorite(Song song) {
    return _favorites.any((s) => s.id == song.id && s.source == song.source);
  }

  /// 批量从收藏中移除歌曲
  Future<int> batchRemoveFavorites(List<Song> songs) async {
    await init();
    final songKeys = songs.map((s) => s.key).toSet();
    final initialCount = _favorites.length;
    _favorites.removeWhere((s) => songKeys.contains(s.key));
    final removed = initialCount - _favorites.length;
    if (removed > 0) {
      await _persist();
      _favoritesController.add(List.from(_favorites));
    }
    return removed;
  }

  /// 记录播放历史
  Future<void> addHistory(Song song) async {
    await init();
    _history.removeWhere((s) => s.id == song.id && s.source == song.source);
    _history.insert(0, song);
    if (_history.length > 60) {
      _history.removeLast();
    }
    await _persist();
    _historyController.add(List.from(_history));
  }

  /// 单条删除历史记录
  Future<void> deleteHistory(String songIdOrKey) async {
    await init();
    _history.removeWhere((s) => s.key == songIdOrKey || s.id == songIdOrKey);
    await _persist();
    _historyController.add(List.from(_history));
  }

  /// 批量删除历史记录
  Future<void> batchDeleteHistory(List<String> songIdsOrKeys) async {
    await init();
    final idSet = songIdsOrKeys.toSet();
    _history.removeWhere((s) => idSet.contains(s.key) || idSet.contains(s.id));
    await _persist();
    _historyController.add(List.from(_history));
  }

  /// 清空历史记录
  Future<void> clearHistory() async {
    await init();
    _history.clear();
    await _persist();
    _historyController.add([]);
  }

  /// 获取下载存储目录及容量统计
  Future<Map<String, dynamic>> getStorageInfo() async {
    await init();
    int totalBytes = 0;
    String folderPath = '';
    for (final song in _downloads) {
      totalBytes += song.fileSizeBytes;
      if (folderPath.isEmpty && song.localFilePath != null) {
        folderPath = File(song.localFilePath!).parent.path;
      }
    }

    if (folderPath.isEmpty) {
      try {
        final extDirs = await getExternalStorageDirectories(type: StorageDirectory.music);
        if (extDirs != null && extDirs.isNotEmpty) {
          folderPath = extDirs.first.path;
        } else {
          folderPath = (await getApplicationDocumentsDirectory()).path;
        }
      } catch (_) {
        folderPath = '/storage/emulated/0/Music';
      }
    }

    final totalMb = (totalBytes / (1024 * 1024)).toStringAsFixed(1);
    return {
      'count': _downloads.length,
      'totalBytes': totalBytes,
      'totalMb': totalMb,
      'folderPath': folderPath,
    };
  }

  // ==================== 搜索历史管理 ====================

  Future<void> addSearchHistory(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    await init();
    _searchHistory.remove(trimmed);
    _searchHistory.insert(0, trimmed);
    if (_searchHistory.length > 20) {
      _searchHistory.removeLast();
    }
    await _persist();
    _searchHistoryController.add(List.from(_searchHistory));
  }

  Future<void> removeSearchHistory(String keyword) async {
    await init();
    _searchHistory.remove(keyword);
    await _persist();
    _searchHistoryController.add(List.from(_searchHistory));
  }

  Future<void> clearSearchHistory() async {
    await init();
    _searchHistory.clear();
    await _persist();
    _searchHistoryController.add([]);
  }

  // ==================== 自定义歌单管理 ====================

  Future<CustomPlaylist> createPlaylist(String name) async {
    await init();
    final pl = CustomPlaylist(
      id: 'pl_${DateTime.now().millisecondsSinceEpoch}',
      name: name.trim().isEmpty ? '新建歌单' : name.trim(),
      createTime: DateTime.now(),
      songs: [],
    );
    _playlists.insert(0, pl);
    await _persist();
    _playlistsController.add(List.from(_playlists));
    return pl;
  }

  Future<void> renamePlaylist(String id, String newName) async {
    await init();
    final idx = _playlists.indexWhere((p) => p.id == id);
    if (idx != -1) {
      _playlists[idx].name = newName.trim().isEmpty ? '未命名歌单' : newName.trim();
      await _persist();
      _playlistsController.add(List.from(_playlists));
    }
  }

  Future<void> deletePlaylist(String id) async {
    await init();
    _playlists.removeWhere((p) => p.id == id);
    await _persist();
    _playlistsController.add(List.from(_playlists));
  }

  Future<bool> addSongToPlaylist(String playlistId, Song song) async {
    await init();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return false;
    final pl = _playlists[idx];
    if (pl.songs.any((s) => s.id == song.id && s.source == song.source)) {
      return false; // 已在歌单中
    }
    pl.songs.insert(0, song);
    await _persist();
    _playlistsController.add(List.from(_playlists));
    return true;
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songIdOrKey) async {
    await init();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx != -1) {
      _playlists[idx].songs.removeWhere((s) => s.key == songIdOrKey || s.id == songIdOrKey);
      await _persist();
      _playlistsController.add(List.from(_playlists));
    }
  }

  Future<void> batchRemoveSongsFromPlaylist(String playlistId, List<String> songIdsOrKeys) async {
    await init();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx != -1) {
      final idSet = songIdsOrKeys.toSet();
      _playlists[idx].songs.removeWhere((s) => idSet.contains(s.key) || idSet.contains(s.id));
      await _persist();
      _playlistsController.add(List.from(_playlists));
    }
  }

  /// 批量将歌曲从源歌单移动到目标歌单
  Future<int> batchMoveSongsToPlaylist({
    required String sourcePlaylistId,
    required String targetPlaylistId,
    required List<Song> songs,
  }) async {
    await init();
    if (sourcePlaylistId == targetPlaylistId || songs.isEmpty) return 0;
    final sourceIdx = _playlists.indexWhere((p) => p.id == sourcePlaylistId);
    final targetIdx = _playlists.indexWhere((p) => p.id == targetPlaylistId);
    if (sourceIdx == -1 || targetIdx == -1) return 0;

    final targetPl = _playlists[targetIdx];
    int movedCount = 0;
    final songKeySet = songs.map((s) => s.key).toSet();

    for (final song in songs) {
      if (!targetPl.songs.any((s) => s.key == song.key || (s.id == song.id && s.source == song.source))) {
        targetPl.songs.insert(0, song);
        movedCount++;
      }
    }

    _playlists[sourceIdx].songs.removeWhere((s) => songKeySet.contains(s.key));
    await _persist();
    _playlistsController.add(List.from(_playlists));
    return movedCount;
  }

  /// 调整歌单内部歌曲顺序 (拖拽重排)
  Future<void> reorderPlaylistSongs(String playlistId, int oldIndex, int newIndex) async {
    await init();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return;
    final list = _playlists[idx].songs;
    if (oldIndex < 0 || oldIndex >= list.length) return;
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (newIndex < 0 || newIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    await _persist();
    _playlistsController.add(List.from(_playlists));
  }

  /// 调整歌单合集排序 (长按拖拽重排并持久化)
  Future<void> reorderPlaylists(int oldIndex, int newIndex) async {
    await init();
    if (oldIndex < 0 || oldIndex >= _playlists.length) return;
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    if (newIndex < 0 || newIndex >= _playlists.length) return;
    if (oldIndex == newIndex) return;
    final item = _playlists.removeAt(oldIndex);
    _playlists.insert(newIndex, item);
    await _persist();
    _playlistsController.add(List.from(_playlists));
  }

  /// 批量更新歌单内部歌曲顺序 (按规则排序)
  Future<void> updatePlaylistSongOrder(String playlistId, List<Song> newSongs) async {
    await init();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return;
    _playlists[idx].songs.clear();
    _playlists[idx].songs.addAll(newSongs);
    await _persist();
    _playlistsController.add(List.from(_playlists));
  }

  /// 歌单单曲置顶到第 1 首
  Future<void> moveSongToTop(String playlistId, String songIdOrKey) async {
    await init();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return;
    final list = _playlists[idx].songs;
    final sIdx = list.indexWhere((s) => s.key == songIdOrKey || s.id == songIdOrKey);
    if (sIdx > 0) {
      final s = list.removeAt(sIdx);
      list.insert(0, s);
      await _persist();
      _playlistsController.add(List.from(_playlists));
    }
  }

  /// 查询某首歌曲当前所属的歌单合集列表 (兼容匹配 key 与 id)
  List<CustomPlaylist> getPlaylistsContainingSong(String songIdOrKey) {
    return _playlists.where((p) => p.songs.any((s) => s.key == songIdOrKey || s.id == songIdOrKey)).toList();
  }

  /// 查询某首歌曲当前所属的歌单合集名称列表 (兼容匹配 key 与 id)
  List<String> getPlaylistNamesForSong(String songIdOrKey) {
    return _playlists
        .where((p) => p.songs.any((s) => s.key == songIdOrKey || s.id == songIdOrKey))
        .map((p) => p.name)
        .toList();
  }

  /// 批量添加歌曲到指定歌单合集（复制/引用模式）
  Future<int> batchAddSongsToPlaylist(String playlistId, List<Song> songs) async {
    await init();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return 0;
    final pl = _playlists[idx];
    int addedCount = 0;
    for (final song in songs) {
      if (!pl.songs.any((s) => s.key == song.key || (s.id == song.id && s.source == song.source))) {
        pl.songs.insert(0, song);
        addedCount++;
      }
    }
    if (addedCount > 0) {
      await _persist();
      _playlistsController.add(List.from(_playlists));
    }
    return addedCount;
  }

  /// 一键更新单首歌曲所属的歌单合集归属（勾选加入，去勾移出）
  Future<void> updateSongPlaylists(Song song, List<String> targetPlaylistIds) async {
    await init();
    final targetSet = targetPlaylistIds.toSet();
    bool changed = false;

    for (final pl in _playlists) {
      final isInPl = pl.songs.any((s) => s.key == song.key || (s.id == song.id && s.source == song.source));
      if (targetSet.contains(pl.id) && !isInPl) {
        pl.songs.insert(0, song);
        changed = true;
      } else if (!targetSet.contains(pl.id) && isInPl) {
        pl.songs.removeWhere((s) => s.key == song.key || (s.id == song.id && s.source == song.source));
        changed = true;
      }
    }

    if (changed) {
      await _persist();
      _playlistsController.add(List.from(_playlists));
    }
  }

  // ==================== 导出到手机公共存储与本地扫描 ====================

  /// 导出单首歌曲到设备公共目录 (/storage/emulated/0/Music/DMusic 或 /storage/emulated/0/Download/DMusic)
  Future<String?> exportSongToPublic(Song song) async {
    if (song.localFilePath == null) return null;
    final srcFile = File(song.localFilePath!);
    if (!await srcFile.exists()) return null;

    final targetDirs = [
      Directory('/storage/emulated/0/Music/DMusic'),
      Directory('/storage/emulated/0/Download/DMusic'),
    ];

    Directory? validDir;
    for (final dir in targetDirs) {
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        validDir = dir;
        break;
      } catch (_) {}
    }

    if (validDir == null) {
      try {
        final extDirs = await getExternalStorageDirectories(type: StorageDirectory.music);
        if (extDirs != null && extDirs.isNotEmpty) {
          validDir = extDirs.first;
        }
      } catch (_) {}
    }

    if (validDir == null) return null;

    final fileName = srcFile.uri.pathSegments.last;
    final destFile = File('${validDir.path}/$fileName');
    await srcFile.copy(destFile.path);

    // 同步复制 LRC 歌词
    if (song.lrcPath != null) {
      final lrcFile = File(song.lrcPath!);
      if (await lrcFile.exists()) {
        try {
          final lrcName = lrcFile.uri.pathSegments.last;
          await lrcFile.copy('${validDir.path}/$lrcName');
        } catch (_) {}
      }
    }

    return destFile.path;
  }

  /// 批量导出歌曲到公共存储
  Future<Map<String, dynamic>> batchExportSongs(List<Song> songs) async {
    int count = 0;
    String targetPath = '';
    for (final song in songs) {
      final exported = await exportSongToPublic(song);
      if (exported != null) {
        count++;
        if (targetPath.isEmpty) {
          targetPath = File(exported).parent.path;
        }
      }
    }
    return {
      'count': count,
      'targetPath': targetPath.isNotEmpty ? targetPath : '/storage/emulated/0/Music/DMusic',
    };
  }

  /// 扫描手机本地音乐并导入到曲库
  Future<int> scanDeviceMusic() async {
    await init();
    final scanDirs = [
      Directory('/storage/emulated/0/Music'),
      Directory('/storage/emulated/0/Download'),
      Directory('/storage/emulated/0/Download/DMusic'),
      Directory('/storage/emulated/0/Music/DMusic'),
    ];

    final audioExts = {'.mp3', '.flac', '.wav', '.m4a', '.ogg', '.aac'};
    int newCount = 0;
    final existingPaths = _downloads.map((s) => s.localFilePath).whereType<String>().toSet();

    for (final dir in scanDirs) {
      if (!await dir.exists()) continue;
      try {
        final entities = dir.listSync(recursive: true, followLinks: false);
        for (final entity in entities) {
          if (entity is File) {
            final lowerPath = entity.path.toLowerCase();
            final hasAudioExt = audioExts.any((ext) => lowerPath.endsWith(ext));
            if (hasAudioExt && !existingPaths.contains(entity.path)) {
              try {
                final info = await AudioInspector.inspect(entity);
                if (!info.isValid || info.hasVideo) continue;
                final filename = entity.uri.pathSegments.last;
                final cleanName = filename.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');
                String songName = cleanName;
                String artist = '本地歌手';
                if (cleanName.contains(' - ')) {
                  final parts = cleanName.split(' - ');
                  artist = parts[0].trim();
                  songName = parts.sublist(1).join(' - ').trim();
                }

                final song = Song(
                  id: 'local_${DateTime.now().millisecondsSinceEpoch}_$newCount',
                  name: songName,
                  artist: artist,
                  album: '本地曲库',
                  source: '本地扫描',
                  quality: Song.cleanQuality(info.qualityLabel),
                  size: info.sizeMb,
                  fileSizeBytes: info.fileSizeBytes,
                  durationSeconds: info.durationSeconds,
                  isLossless: info.isLossless,
                  localFilePath: entity.path,
                  downloadTime: DateTime.now(),
                );

                _downloads.insert(0, song);
                existingPaths.add(entity.path);
                newCount++;
              } catch (_) {
                // 单个损坏或无法读取的文件不影响同目录内其余音频。
              }
            }
          }
        }
      } catch (_) {}
    }

    if (newCount > 0) {
      await _persist();
      _downloadsController.add(List.from(_downloads));
    }
    return newCount;
  }
}
