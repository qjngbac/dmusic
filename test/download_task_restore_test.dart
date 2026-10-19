import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:dmusic_app/models/song.dart';
import 'package:dmusic_app/services/download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'audio_fixtures.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

void main() {
  test('a stored failure mentioning retry keeps its original reason', () async {
    final result = await Isolate.run(() async {
      final dir = await Directory.systemTemp.createTemp('dmusic-task-status-');
      PathProviderPlatform.instance = _Paths(dir.path);
      try {
        final file = File('${dir.path}/dmusic_download_tasks.json');
        const reason = '下载失败：请求超时，请稍后重试';
        await file.writeAsString(jsonEncode([DownloadTask(song: Song(id: 'failed',
          name: 'Failure', artist: 'Artist', album: '', source: 'QQ音乐'), status: reason).toJson()]));
        await DownloadService().init();
        return DownloadService().tasks.single.status;
      } finally { await dir.delete(recursive: true); }
    });
    expect(result, '下载失败：请求超时，请稍后重试');
  });

  for (final malformed in ['[{}]', '[{"song":42}]', '[null]']) {
    test('task schema $malformed recovers the valid backup without overwriting it', () async {
      final result = await Isolate.run(() async {
        final dir = await Directory.systemTemp.createTemp('dmusic-task-backup-');
        PathProviderPlatform.instance = _Paths(dir.path);
        try {
          final backup = jsonEncode([DownloadTask(song: Song(id: 'kept',
            name: 'Kept task', artist: 'Artist', album: '', source: 'QQ音乐'),
            targetQuality: '320k').toJson()]);
          final mainFile = File('${dir.path}/dmusic_download_tasks.json');
          final backupFile = File('${mainFile.path}.bak');
          await mainFile.writeAsString(malformed);
          await backupFile.writeAsString(backup);
          await DownloadService().init();
          return {
            'ids': DownloadService().tasks.map((task) => task.song.id).toList(),
            'status': DownloadService().tasks.isEmpty ? '' : DownloadService().tasks.single.status,
            'backupUnchanged': await backupFile.readAsString() == backup,
            'primaryCount': (jsonDecode(await mainFile.readAsString()) as List).length,
          };
        } finally { await dir.delete(recursive: true); }
      });
      expect(result['ids'], ['kept']);
      expect(result['status'], contains('未完成'));
      expect(result['backupUnchanged'], true);
      expect(result['primaryCount'], 1);
    });
  }

  test('two malformed task files preserve their original contents', () async {
    final result = await Isolate.run(() async {
      final dir = await Directory.systemTemp.createTemp('dmusic-task-corrupt-');
      PathProviderPlatform.instance = _Paths(dir.path);
      try {
        final mainFile = File('${dir.path}/dmusic_download_tasks.json');
        final backupFile = File('${mainFile.path}.bak');
        await mainFile.writeAsString('[{}]');
        await backupFile.writeAsString('[{"song":false}]');
        await DownloadService().init();
        return {'main': await mainFile.readAsString(), 'backup': await backupFile.readAsString()};
      } finally { await dir.delete(recursive: true); }
    });
    expect(result, {'main': '[{}]', 'backup': '[{"song":false}]'});
  });

  test(
    'restoring a formerly completed preview marks it failed without deleting it',
    () async {
      final result = await Isolate.run(() async {
        final dir = await Directory.systemTemp.createTemp(
          'dmusic-task-restore-',
        );
        PathProviderPlatform.instance = _Paths(dir.path);
        try {
          final file = await File(
            '${dir.path}/preview.mp3',
          ).writeAsBytes(mp3Fixture(frames: 2300));
          final song = Song(
            id: '1',
            name: 'Song',
            artist: 'Artist',
            album: '',
            source: 'QQ音乐',
            durationSeconds: 180,
            localFilePath: file.path,
          );
          final task = DownloadTask(
            song: song,
            savedPath: file.path,
            status: '已完成',
            targetQuality: '128k',
          );
          await File(
            '${dir.path}/dmusic_download_tasks.json',
          ).writeAsString(jsonEncode([task.toJson()]));
          await DownloadService().init();
          return {
            'status': DownloadService().tasks.single.status,
            'exists': await file.exists(),
          };
        } finally {
          await dir.delete(recursive: true);
        }
      });
      expect(result['status'], contains('失败'));
      expect(result['exists'], isTrue);
    },
  );
}
