import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import '../models/song.dart';
import 'music_api.dart';
import 'database_service.dart';
import 'audio_inspector.dart';
import 'playback_cache_service.dart';

class DownloadTask {
  Song song;
  double progress;
  String speed;
  String status; // 等待中, 下载中, 已完成, 失败/受限, 已取消, 未完成 (点击恢复)
  String? savedPath;
  bool preferLossless;
  String targetQuality;
  DateTime createTime;

  DownloadTask({
    required this.song,
    this.progress = 0.0,
    this.speed = '',
    this.status = '等待中',
    this.savedPath,
    this.preferLossless = true,
    this.targetQuality = '',
    DateTime? createTime,
  }) : createTime = createTime ?? DateTime.now();

  /// 优先获取物理文件真实大小，未下载完成时明确标明为预估
  String get displaySizeStr {
    final p = savedPath ?? song.localFilePath;
    if (p != null && p.isNotEmpty) {
      try {
        final f = File(p);
        if (f.existsSync()) {
          final bytes = f.lengthSync();
          if (bytes > 0) {
            final mb = bytes / (1024 * 1024);
            return '${mb.toStringAsFixed(1)}MB';
          }
        }
      } catch (_) {}
    }
    if (song.fileSizeBytes > 0 && status == '已完成') {
      final mb = song.fileSizeBytes / (1024 * 1024);
      return '${mb.toStringAsFixed(1)}MB';
    }
    if (status.contains('失败')) {
      return '预估 ${song.estimatedSizeStr}';
    }
    if (status == '等待中' || status.contains('下载中') || status.contains('解析')) {
      return '预估 ${song.estimatedSizeStr}';
    }
    return song.estimatedSizeStr;
  }

  Map<String, dynamic> toJson() => {
    'song': song.toJson(),
    'progress': progress,
    'status': status,
    'savedPath': savedPath,
    'preferLossless': preferLossless,
    'targetQuality': targetQuality,
    'createTime': createTime.toIso8601String(),
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      song: Song.fromJson(json['song']),
      progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
      status: json['status'] as String? ?? '等待中',
      savedPath: json['savedPath'] as String?,
      preferLossless: json['preferLossless'] as bool? ?? true,
      targetQuality: json['targetQuality'] as String? ?? '',
      createTime: json['createTime'] != null ? DateTime.tryParse(json['createTime']) : null,
    );
  }
}

class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  final List<DownloadTask> _tasks = [];
  final _tasksController = StreamController<List<DownloadTask>>.broadcast();

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  Stream<List<DownloadTask>> get tasksStream => _tasksController.stream;

  bool _initialized = false;
  bool _hasLoadFailure = false;
  bool _loadedFromBackup = false;
  File? _tasksFile;
  File? _tasksBakFile;
  Timer? _saveDebounceTimer;
  final Map<String, http.Client> _activeClients = {};
  final Map<String, StreamSubscription<List<int>>> _activeSubscriptions = {};
  final Map<String, int> _runIds = {};
  final Map<String, Completer<void>> _downloadCompletions = {};
  Future<void> _saveQueue = Future.value();
  int _activeDownloads = 0;
  final Map<DownloadTask, ({int runId, Completer<bool> ready})> _slotWaiters = {};

  bool _hasSavedLocalResult(DownloadTask task) => task.status == '已完成' ||
      task.status.startsWith('下载失败：已有文件') ||
      task.status.startsWith('本地校验失败') ||
      task.status.startsWith('本地文件') ||
      (task.savedPath != null && task.status.contains('失败'));

  Future<void> _restoreSavedTask(DownloadTask task) async {
    final paths = <String>{
      if (task.savedPath?.isNotEmpty == true) task.savedPath!,
      if (task.song.localFilePath?.isNotEmpty == true) task.song.localFilePath!,
      for (final song in DatabaseService().downloads)
        if (song.key == task.song.key && song.localFilePath?.isNotEmpty == true)
          song.localFilePath!,
    };
    for (final path in paths) {
      try {
        final file = File(path);
        if (AudioInspector.isQuickValidAudioFile(file)) {
          final len = file.lengthSync();
          task.savedPath = path;
          task.song = task.song.copyWith(
            localFilePath: path,
            fileSizeBytes: len,
            size: '${(len / (1024 * 1024)).toStringAsFixed(1)}MB',
          );
          task.status = '已完成';
          task.progress = 1.0;
          task.speed = '';
          return;
        }
      } catch (_) {}
    }
    if (task.status == '已完成' ||
        task.status.contains('本地校验失败') ||
        task.status.contains('未找到')) {
      task.status = '本地文件缺失或暂不可访问 (点击恢复)';
      task.progress = 0;
      task.speed = '';
    }
  }

  /// 初始化并从磁盘恢复已有下载任务
  Future<void> init() async {
    if (_initialized) return;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _tasksFile = File('${appDir.path}/dmusic_download_tasks.json');
      _tasksBakFile = File('${appDir.path}/dmusic_download_tasks.json.bak');
      await DatabaseService().init();

      List<dynamic>? list;
      var hadStoredTasks = false;
      for (final storedFile in [_tasksFile!, _tasksBakFile!]) {
        if (!await storedFile.exists()) continue;
        hadStoredTasks = true;
        try {
          final decoded = jsonDecode(await storedFile.readAsString());
          if (decoded is! List) continue;
          // Validate the whole snapshot before choosing it. Skipping bad rows
          // here would silently replace both the task file and a valid backup.
          for (final item in decoded) {
            if (item is! Map || item['song'] is! Map) {
              throw const FormatException('下载任务记录结构损坏');
            }
            final task = DownloadTask.fromJson(Map<String, dynamic>.from(item));
            if (task.song.id.isEmpty) throw const FormatException('下载任务缺少歌曲标识');
          }
          list = decoded;
          _loadedFromBackup = storedFile.path == _tasksBakFile!.path;
          break;
        } catch (_) {}
      }
      _hasLoadFailure = hadStoredTasks && list == null;
      if (_hasLoadFailure) {
        _initialized = true;
        _notify();
        return;
      }

      if (list != null) {
        _tasks.clear();
        for (final item in list) {
          try {
            final task = DownloadTask.fromJson(item as Map<String, dynamic>);
            if (_hasSavedLocalResult(task)) {
              await _restoreSavedTask(task);
              _tasks.add(task);
            } else if (!task.status.contains('失败') &&
                       !task.status.contains('受限') &&
                       !task.status.contains('限制') &&
                       !task.status.contains('版权') &&
                       (task.status.contains('下载中') ||
                        task.status.contains('准备') ||
                        task.status.contains('解析') ||
                        task.status.contains('等待') ||
                        task.status.contains('重试'))) {
              // 应用退出时处于下载中或未完成的任务，恢复为“未完成”提示
              task.status = '未完成 (点击恢复)';
              task.speed = '';
              _tasks.add(task);
            } else {
              // 失败/受限/已取消等保留原有状态
              task.speed = '';
              _tasks.add(task);
            }
          } catch (_) {}
        }
      }

      // Earlier validation could remove a good library row while the task still
      // held its file path. Rebuild only verified local rows, without a download.
      await DatabaseService().restoreExistingDownloads(
        _tasks.where((task) => task.status == '已完成').map((task) => task.song),
      );

      // 如果任务队列仍为空（例如首次升级至支持持久化的版本），自动从已下载曲库中导入已完成记录
      if (_tasks.isEmpty) {
        final downloadedSongs = DatabaseService().downloads;
        for (final s in downloadedSongs) {
          if (s.localFilePath != null) {
            final f = File(s.localFilePath!);
            if (AudioInspector.isQuickValidAudioFile(f)) {
              try {
                final bytes = f.lengthSync();
                s.fileSizeBytes = bytes;
                final mb = bytes / (1024 * 1024);
                s.size = '${mb.toStringAsFixed(1)}MB';
              } catch (_) {}
              _tasks.add(DownloadTask(
                song: s,
                progress: 1.0,
                status: '已完成',
                savedPath: s.localFilePath,
                preferLossless: s.isLossless,
              ));
            }
          }
        }
        if (_tasks.isNotEmpty) {
          _saveTasks(immediate: true);
        }
      }

      _initialized = true;
      await _doSave();
      _notify();
    } catch (_) {
      _initialized = true;
    }
  }

  /// 本地原子写入任务持久化文件
  void _saveTasks({bool immediate = false}) {
    if (_tasksFile == null) return;
    if (immediate) {
      _saveDebounceTimer?.cancel();
      _doSave();
    } else {
      _saveDebounceTimer?.cancel();
      _saveDebounceTimer = Timer(const Duration(milliseconds: 800), _doSave);
    }
  }

  Future<void> _doSave() {
    _saveQueue = _saveQueue.then((_) => _writeTasks());
    return _saveQueue;
  }

  Future<void> _writeTasks() async {
    if (_tasksFile == null || _hasLoadFailure) return;
    try {
      final jsonStr = jsonEncode(_tasks.map((t) => t.toJson()).toList());
      final tempFile = File('${_tasksFile!.path}.tmp');
      await tempFile.writeAsString(jsonStr, flush: true);

      if (!_loadedFromBackup && await _tasksFile!.exists()) {
        try {
          if (_tasksBakFile != null) {
            await _tasksFile!.copy(_tasksBakFile!.path);
          }
        } catch (_) {}
      }

      await tempFile.rename(_tasksFile!.path);
      _loadedFromBackup = false;
    } catch (_) {}
  }

  void _interrupt(DownloadTask task) {
    final key = task.song.key;
    _runIds[key] = (_runIds[key] ?? 0) + 1;
    _activeSubscriptions.remove(key)?.cancel();
    _activeClients.remove(key)?.close();
    final completion = _downloadCompletions.remove(key);
    if (completion != null && !completion.isCompleted) completion.complete();
    _slotWaiters.remove(task)?.ready.complete(false);
  }

  void removeTask(String songIdOrKey, {String? source}) {
    final removed = _tasks.where((task) =>
      (task.song.key == songIdOrKey || task.song.id == songIdOrKey) &&
      (source == null || task.song.source == source)).toList();
    for (final task in removed) { _interrupt(task); }
    _tasks.removeWhere(removed.contains);
    _notify();
    _saveTasks(immediate: true);
  }

  void pauseTask(DownloadTask task) {
    if (task.status == '已完成' || task.status == '已取消') return;
    _interrupt(task);
    task.status = '已暂停 (点击恢复)';
    task.speed = '';
    _notify();
    _saveTasks(immediate: true);
  }

  void resumeTask(DownloadTask task) {
    startDownload(task.song, preferLossless: task.preferLossless, targetQuality: task.targetQuality);
  }

  /// 一键批量恢复所有未完成/失败的下载任务
  void resumeAll() {
    final toResume = _tasks.where((t) =>
      t.status.contains('未完成') ||
      t.status.contains('暂停') ||
      t.status.contains('中断') ||
      t.status.contains('失败') ||
      t.status.contains('限制') ||
      t.status.contains('本地文件')
    ).toList();

    for (final t in toResume) {
      resumeTask(t);
    }
  }

  bool _isCurrent(DownloadTask task, int runId) =>
      _runIds[task.song.key] == runId && _tasks.contains(task);

  Future<bool> _acquireSlot(DownloadTask task, int runId) {
    if (_activeDownloads < 3) {
      _activeDownloads++;
      return Future.value(true);
    }
    final ready = Completer<bool>();
    _slotWaiters[task] = (runId: runId, ready: ready);
    return ready.future;
  }

  void _releaseSlot() {
    _activeDownloads--;
    while (_slotWaiters.isNotEmpty) {
      final entry = _slotWaiters.entries.first;
      _slotWaiters.remove(entry.key);
      if (_isCurrent(entry.key, entry.value.runId)) {
        _activeDownloads++;
        entry.value.ready.complete(true);
        return;
      }
      entry.value.ready.complete(false);
    }
  }

  Future<Directory> _downloadDirectory() async {
    try {
      final publicMusic = Directory('/storage/emulated/0/Music');
      if (await publicMusic.exists()) {
        final probe = File('${publicMusic.path}/.dmusic_test_${DateTime.now().microsecondsSinceEpoch}');
        await probe.writeAsString('ok');
        await probe.delete();
        return publicMusic;
      }
    } catch (_) {}
    try {
      final dirs = await getExternalStorageDirectories(type: StorageDirectory.music);
      if (dirs != null && dirs.isNotEmpty) return dirs.first;
    } catch (_) {}
    return await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
  }

  String _failureReason(Object error) {
    if (error is TimeoutException) return '网络连接或音频传输超时，请稍后重试';
    if (error is http.ClientException || error is SocketException) return '网络连接中断或不可用，请检查网络后重试';
    if (error is FileSystemException) return '文件保存失败，请检查存储空间和访问权限';
    if (error is FormatException) return error.message;
    return '下载或保存失败，请稍后重试';
  }

  Future<void> startDownload(Song originalSong, {bool preferLossless = true, String targetQuality = ''}) async {
    final quality = targetQuality.isNotEmpty ? targetQuality : (preferLossless ? 'flac' : '320k');
    if (!{'flac', '320k', '128k'}.contains(quality)) {
      throw ArgumentError.value(quality, 'targetQuality', '不支持的下载档位');
    }
    if (_tasks.any((t) => t.song.key == originalSong.key &&
        (t.status == '等待中' || t.status == '下载中' || t.status.contains('解析') || t.status.contains('重试')))) { return; }
    final songQualityLabel = quality == 'flac' ? 'FLAC 无损' : (quality == '320k' ? '320k 极高' : '128k 标准');
    final songIsLossless = quality == 'flac';
    final song = originalSong.copyWith(
        quality: songQualityLabel,
        isLossless: songIsLossless,
        audioUrl: null, audioUrlTimestamp: null,
        audioUrlQuality: null, audioUrlSource: null, localFilePath: null, lrcPath: null,
        fileSizeBytes: 0, size: '');
    _tasks.removeWhere((t) => t.song.key == song.key);
    final task = DownloadTask(song: song, preferLossless: quality == 'flac', targetQuality: quality);
    final runId = (_runIds[song.key] ?? 0) + 1;
    _runIds[song.key] = runId;
    _tasks.insert(0, task);
    _notify();
    _saveTasks(immediate: true);
    File? partial;
    File? publishedFile;
    File? createdLyric;
    CachedPlayback? cached;
    var registered = false;
    var hasSlot = false;
    var failureReason = quality == '320k'
        ? '未找到320k音源 (可换源或选无损FLAC)'
        : '未找到符合所选音质的完整音源';
    try {
      hasSlot = await _acquireSlot(task, runId);
      if (!hasSlot || !_isCurrent(task, runId)) return;
      task.status = '解析链接...';
      _notify();
      final excluded = <String>{};
      try {
        cached = await PlaybackCacheService.instance.find(originalSong,
            targetQuality: quality, forDownload: true);
      } catch (_) { /* Cache failures fall back to the normal download path. */ }
      if (!_isCurrent(task, runId)) return;
      var url = cached == null
          ? await MusicApi.resolveAudioUrl(song, preferLossless: quality == 'flac',
              forceRefresh: true, targetQuality: quality)
          : null;
      if (!_isCurrent(task, runId)) return;
      final directory = await _downloadDirectory();
      if (!_isCurrent(task, runId)) return;
      await directory.create(recursive: true);
      final cleanName = '${song.artist} - ${song.name}'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final identity = md5.convert(utf8.encode(song.key)).toString().substring(0, 8);
      final basePath = '${directory.path}/${cleanName}_${identity}_${DateTime.now().microsecondsSinceEpoch}';
      final attempts = cached == null ? 2 : 3;
      for (var attempt = 0; attempt < attempts; attempt++) {
        if (cached == null && (url == null || url.isEmpty)) break;
        if (!_isCurrent(task, runId)) return;
        partial = File('$basePath.part');
        await partial.create(exclusive: true);
        RealAudioInfo? info;
        try {
          task.status = attempt == 0 ? '下载中' : '切换全网备选源重试...';
          task.progress = 0;
          _notify();
          if (cached != null) {
            final lease = cached;
            cached = null;
            try {
              await lease.file.copy(partial.path);
            } finally {
              try { await lease.release(); } catch (_) {}
            }
          } else {
            await _downloadFile(task, runId, url!, partial);
          }
          if (!_isCurrent(task, runId)) return;
          info = await AudioInspector.inspect(partial, strict: true);
          if (!info.isValid) {
            failureReason = '音频结构校验未通过或文件损坏';
            info = null;
          } else if (info.hasVideo) {
            failureReason = '返回文件含视频，未作为纯音频保存';
            info = null;
          } else if (!info.matchesQuality(quality)) {
            failureReason = '源站实际返回${info.qualityLabel}，未达到所选${quality == 'flac' ? '无损' : quality}规格';
            info = null;
          } else {
            final durSec = info.durationSeconds > 0
                ? info.durationSeconds
                : (info.bitrateKbps > 0 && info.fileSizeBytes > 0 ? (info.fileSizeBytes * 8 / (info.bitrateKbps * 1000)).round() : 0);
            final origDur = originalSong.durationSeconds;
            final isSnippet = (durSec > 0 && durSec <= 90) ||
                (origDur > 60 && durSec > 0 && durSec < origDur * 0.75) ||
                (origDur > 60 && durSec <= 0 && info.fileSizeBytes < 2.5 * 1024 * 1024);
            if (isSnippet) {
              failureReason = '返回内容为试听片段（仅${durSec > 0 ? '$durSec秒' : info.sizeMb}，已拦截）';
              info = null;
            }
          }
        } catch (error) {
          if (!_isCurrent(task, runId)) return;
          failureReason = _failureReason(error);
          info = null;
        }
        if (info != null) {
          if (!_isCurrent(task, runId)) return;
          String? lrcPath;
          try {
            final text = await MusicApi.fetchLyric(song);
            if (!_isCurrent(task, runId)) return;
            if (text != null && text.isNotEmpty) {
              final file = File('$basePath.lrc');
              createdLyric = file;
              await file.writeAsString(text);
              lrcPath = file.path;
            }
          } catch (_) {}
          if (!_isCurrent(task, runId)) return;
          final finalFile = await partial.rename('$basePath.${info.realExtension}');
          partial = null;
          publishedFile = finalFile;
          if (!_isCurrent(task, runId)) return;
          final realSong = song.copyWith(quality: info.qualityLabel, isLossless: info.isLossless,
              durationSeconds: info.durationSeconds > 0 ? info.durationSeconds : originalSong.durationSeconds,
              fileSizeBytes: info.fileSizeBytes, size: info.sizeMb, localFilePath: finalFile.path, lrcPath: lrcPath);
          final registeredSong = await DatabaseService().addDownload(realSong, finalFile,
              lrcPath: lrcPath, isCurrent: () => _isCurrent(task, runId));
          if (!_isCurrent(task, runId)) return;
          registered = true;
          task.song = registeredSong;
          task.savedPath = registeredSong.localFilePath;
          task.status = '已完成';
          task.progress = 1;
          task.speed = '';
          _notify();
          _saveTasks(immediate: true);
          return;
        }
        if (await partial.exists()) await partial.delete();
        partial = null;
        if (url != null) excluded.add(url);
        if (attempt < attempts - 1) {
          url = await MusicApi.resolveAudioUrl(song, preferLossless: quality == 'flac',
              forceRefresh: true, targetQuality: quality, excludedUrls: excluded);
        }
      }
      if (!_isCurrent(task, runId)) return;
      task.status = '下载失败：$failureReason (点击换源)';
      task.progress = 0;
      task.speed = '';
      _notify();
      _saveTasks(immediate: true);
    } catch (error) {
      if (!_isCurrent(task, runId)) return;
      task.status = '下载失败：${_failureReason(error)} (点击换源)';
      task.progress = 0;
      task.speed = '';
      _notify();
      _saveTasks(immediate: true);
    } finally {
      try { await cached?.release(); } catch (_) {}
      if (partial != null && await partial.exists()) {
        try { await partial.delete(); } catch (_) {}
      }
      if (!registered) {
        for (final artifact in [publishedFile, createdLyric]) {
          if (artifact != null) {
            try { if (await artifact.exists()) await artifact.delete(); } catch (_) {}
          }
        }
      }
      if (hasSlot) _releaseSlot();
    }
  }

  Future<void> _downloadFile(DownloadTask task, int runId, String url, File file) async {
    final key = task.song.key;
    final client = http.Client();
    _activeClients[key] = client;
    StreamSubscription<List<int>>? subscription;
    final completion = Completer<void>();
    // A disk error can arrive before HTTP headers; observe it immediately even
    // though the transfer awaits this future only after the response starts.
    unawaited(completion.future.catchError((Object _) {}));
    final sink = file.openWrite();
    // IOSink 的异步磁盘错误必须被观察，不能只捕获网络流错误。
    final sinkDone = sink.done;
    sinkDone.catchError((Object error, StackTrace stack) {
      if (!completion.isCompleted) completion.completeError(error, stack);
    });
    try {
      // Attach the file consumer before awaiting the network so open failures
      // cannot escape as an unhandled _FileStreamConsumer future.
      sink.add(const []);
      await sink.flush();
      final request = http.Request('GET', Uri.parse(url))..headers.addAll(MusicApi.audioHeaders(url));
      final response = await client.send(request).timeout(const Duration(seconds: 15));
      if (!_isCurrent(task, runId)) return;
      if (response.statusCode != 200) throw FormatException('音频服务器返回HTTP ${response.statusCode}，未收到完整音频');
      final type = (response.headers['content-type'] ?? '').toLowerCase();
      if (type.contains('text/') || type.contains('json')) throw const FormatException('返回了网页');
      final total = response.contentLength ?? 0;
      var received = 0;
      var previousBytes = 0;
      var previousTime = DateTime.now();
      _downloadCompletions[key] = completion;
      subscription = response.stream.timeout(const Duration(seconds: 30)).listen((chunk) {
        if (!_isCurrent(task, runId)) return;
        received += chunk.length;
        sink.add(chunk);
        final now = DateTime.now();
        final elapsed = now.difference(previousTime).inMilliseconds;
        if (elapsed >= 400) {
          task.speed = '${((received - previousBytes) / elapsed / 1024).toStringAsFixed(2)} MB/s';
          task.progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
          previousTime = now;
          previousBytes = received;
          _notify();
        }
      }, onDone: () { if (!completion.isCompleted) completion.complete(); },
          onError: (Object error, StackTrace stack) { if (!completion.isCompleted) completion.completeError(error, stack); });
      _activeSubscriptions[key] = subscription;
      await completion.future;
      await subscription.cancel();
      await sink.flush();
      if (!_isCurrent(task, runId)) return;
      if (received == 0 || (total > 0 && received != total)) throw const FormatException('音频传输不完整');
    } finally {
      await subscription?.cancel();
      try { await sink.close(); } catch (_) {}
      client.close();
      if (identical(_activeClients[key], client)) _activeClients.remove(key);
      if (identical(_activeSubscriptions[key], subscription)) _activeSubscriptions.remove(key);
      if (identical(_downloadCompletions[key], completion)) _downloadCompletions.remove(key);
    }
  }

  void cancelTask(DownloadTask task) {
    if (task.status == '已完成') return;
    _interrupt(task);
    task.status = '已取消';
    task.speed = '';
    _notify();
    _saveTasks(immediate: true);
  }

  void removeTasks(List<String> keysOrIds) {
    final keys = keysOrIds.toSet();
    final removed = _tasks.where((t) => keys.contains(t.song.key) || keys.contains(t.song.id)).toList();
    for (final task in removed) { _interrupt(task); }
    _tasks.removeWhere(removed.contains);
    _notify();
    _saveTasks(immediate: true);
  }

  /// 清理所有已完成与已取消的任务
  void clearCompleted() {
    _tasks.removeWhere((t) => t.status == '已完成' || t.status == '已取消');
    _notify();
    _saveTasks(immediate: true);
  }

  /// 一键清理所有受限、失效与失败的任务
  void clearFailed() {
    _tasks.removeWhere((t) => t.status.contains('失败') || t.status.contains('失效') || t.status.contains('限制') || t.status.contains('版权') || t.status.contains('本地文件'));
    _notify();
    _saveTasks(immediate: true);
  }

  void _notify() {
    _tasksController.add(List.from(_tasks));
  }
}
