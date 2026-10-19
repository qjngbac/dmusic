import 'dart:async';
import 'dart:io';
import '../models/song.dart';
import 'database_service.dart';
import 'audio_inspector.dart';

class ConversionTask {
  final File sourceFile;
  final String title;
  final String artist;
  final String targetFormat; // mp3, wav, flac, aac, m4a
  final String targetBitrate; // 320k, 256k, 192k, 128k
  final int sampleRate; // 44100, 48000
  final bool saveToLibrary;
  final bool exportToPublic;
  double progress = 0.0;
  String status = '等待中'; // 等待中, 转换中, 已完成, 失败
  String? outputPath;
  String? exportedPublicPath;
  int outputSizeBytes = 0;
  bool isSavedToLibrary = false;
  String? errorMessage;

  ConversionTask({
    required this.sourceFile,
    required this.title,
    required this.artist,
    required this.targetFormat,
    this.targetBitrate = '320k',
    this.sampleRate = 44100,
    this.saveToLibrary = true,
    this.exportToPublic = false,
  });
}

class AudioConverterService {
  static final AudioConverterService _instance = AudioConverterService._internal();
  factory AudioConverterService() => _instance;
  AudioConverterService._internal();

  final List<ConversionTask> _tasks = [];
  final _tasksController = StreamController<List<ConversionTask>>.broadcast();

  List<ConversionTask> get tasks => List.unmodifiable(_tasks);
  Stream<List<ConversionTask>> get tasksStream => _tasksController.stream;

  Future<ConversionTask> convertAudio({
    required File sourceFile,
    required String title,
    required String artist,
    required String targetFormat,
    String targetBitrate = '320k',
    int sampleRate = 44100,
    bool saveToLibrary = true,
    bool exportToPublic = false,
  }) async {
    final task = ConversionTask(
      sourceFile: sourceFile,
      title: title,
      artist: artist,
      targetFormat: targetFormat.toLowerCase(),
      targetBitrate: targetBitrate,
      sampleRate: sampleRate,
      saveToLibrary: saveToLibrary,
      exportToPublic: exportToPublic,
    );

    _tasks.insert(0, task);
    _notify();

    try {
      if (!await sourceFile.exists()) {
        throw FileSystemException('源音频文件不存在', sourceFile.path);
      }
      // 当前工程没有真实的解码、重采样和编码引擎。禁止复制字节伪装为目标格式。
      throw UnsupportedError('尚未接入真实音频转码引擎，不能修改格式、码率或采样率');
    } catch (error) {
      task.status = '转换失败';
      task.errorMessage = error.toString();
      _notify();
      rethrow;
    }
  }

  /// 手动或自动将转换任务文件导出到外部公共存储
  Future<String?> exportTaskToPublic(ConversionTask task) async {
    final path = task.outputPath;
    if (path == null || !File(path).existsSync()) {
      throw FileSystemException('转换结果不存在', path);
    }
    final src = File(path);

    final targetDirs = [
      Directory('/storage/emulated/0/Music/DMusic'),
      Directory('/storage/emulated/0/Music'),
      Directory('/storage/emulated/0/Download/DMusic'),
      Directory('/storage/emulated/0/Download'),
    ];

    for (final dir in targetDirs) {
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        final fileName = src.uri.pathSegments.last;
        final dest = File('${dir.path}/$fileName');
        await src.copy(dest.path);
        task.exportedPublicPath = dest.path;
        _notify();
        return dest.path;
      } catch (_) {}
    }
    return null;
  }

  /// 手动将尚未存入软件曲库的任务补存入曲库
  Future<Song?> saveTaskToAppLibrary(ConversionTask task) async {
    final path = task.outputPath;
    if (path == null || !File(path).existsSync()) {
      throw FileSystemException('转换结果不存在', path);
    }
    final file = File(path);
    final info = await AudioInspector.inspect(file);
    if (!info.isValid || info.hasVideo) throw const FormatException('转换结果不是有效音频');

    final newSong = Song(
      id: 'conv_${DateTime.now().millisecondsSinceEpoch}',
      name: '${task.title} [${task.targetFormat.toUpperCase()}]',
      artist: task.artist.isEmpty ? '本地转换' : task.artist,
      album: '格式转换工作台',
      source: '本地转换',
      quality: info.qualityLabel,
      isLossless: info.isLossless,
      durationSeconds: info.durationSeconds,
      localFilePath: file.path,
      fileSizeBytes: info.fileSizeBytes,
    );
    final registered = await DatabaseService().addDownload(newSong, file);
    task.outputPath = registered.localFilePath ?? file.path;
    task.outputSizeBytes = registered.fileSizeBytes;
    task.isSavedToLibrary = true;
    _notify();
    return registered;
  }

  void _notify() {
    _tasksController.add(List.from(_tasks));
  }
}
